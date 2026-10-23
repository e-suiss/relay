defmodule Relay.Platform.IntegrityCheckTest do
  use Relay.MaintenanceCase, async: false

  alias Relay.Platform.Maintenance.IntegrityTask

  setup do
    ref = make_ref()
    pid = self()

    :telemetry.attach_many(
      ref,
      [
        [:relay, :integrity, :violation],
        [:relay, :integrity, :clean],
        [:relay, :integrity, :run]
      ],
      fn event, measurements, meta, _ -> send(pid, {event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    :ok
  end

  defp audit_target_orphan!(tenant) do
    scoped(tenant.id, "live", fn ->
      rows!(
        "SELECT relay_fn.audit_append($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        [Relay.Id.generate(), "test.orphaned" | actor()] ++
          ["delivery", Relay.Id.to_string(Relay.Id.generate()), nil, nil, nil, digest()]
      )
    end)
  end

  defp found do
    checks =
      maint_rows!("SELECT check_name, table_name, violations FROM relay_ops.orphan_check()") ++
        maint_rows!("SELECT check_name, table_name, violations FROM relay_ops.reference_check()")

    short =
      for [table, false] <-
            maint_rows!("SELECT table_name, ok FROM relay_ops.partition_horizon()"),
          do: {"partition_horizon", table, 1}

    for([check, table, n] <- checks, n > 0, do: {check, table, n}) ++ short
  end

  test "OP-42: the nightly check reports every orphan, missing scope and missing key it finds" do
    committed(fn ->
      audit_target_orphan!(tenant!())

      assert {:ok, %{"violations" => violations}} = IntegrityTask.check()
      expected = found()

      assert Enum.sort(Enum.map(violations, &{&1["check"], &1["table"], &1["violations"]})) ==
               Enum.sort(expected)

      assert Enum.any?(expected, &match?({"audit_target_missing", "audit_log", _}, &1))

      for {check, table, n} <- expected do
        assert_received {[:relay, :integrity, :violation], %{violations: ^n},
                         %{check: ^check, table: ^table}}
      end

      refute_received {[:relay, :integrity, :violation], _, _}
      refute_received {[:relay, :integrity, :clean], _, _}
    end)
  end

  test "OP-71: every completed nightly run is reported with its time so a stale check alarms" do
    committed(fn ->
      context = %{name: "integrity_check", node: "n", fencing_token: 1, state: nil}
      assert {:ok, %{"checked_at" => checked_at}, delay} = IntegrityTask.run(context)
      assert delay == 24 * 60 * 60_000
      assert {:ok, _, _} = DateTime.from_iso8601(checked_at)
      assert_received {[:relay, :integrity, :run], %{count: 1}, %{}}
    end)
  end

  test "TN-16: a polymorphic audit target that points nowhere is an orphan" do
    committed(fn ->
      audit_target_orphan!(tenant!())

      assert {:ok, %{"violations" => violations}} = IntegrityTask.check()
      assert Enum.any?(violations, &(&1["table"] == "audit_log" and &1["violations"] > 0))
    end)
  end
end
