defmodule Relay.Platform.IntegrityCheckTest do
  use Relay.MaintenanceCase, async: false

  alias Relay.Platform.Maintenance.IntegrityTask

  setup do
    ref = make_ref()
    pid = self()

    :telemetry.attach_many(
      ref,
      [[:relay, :integrity, :violation], [:relay, :integrity, :clean]],
      fn event, measurements, meta, _ -> send(pid, {event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    :ok
  end

  test "OP-42: the nightly check reports every orphan, missing scope and missing key it finds" do
    committed(fn ->
      assert {:ok, %{"violations" => violations}} = IntegrityTask.check()

      orphans =
        maint_rows!("SELECT check_name, table_name, violations FROM relay_ops.orphan_check()")

      expected = for [check, table, n] <- orphans, n > 0, do: {check, table}

      assert MapSet.subset?(
               MapSet.new(expected),
               MapSet.new(violations, &{&1["check"], &1["table"]})
             )

      if violations == [] do
        assert_received {[:relay, :integrity, :clean], _, _}
      else
        for %{"violations" => n, "check" => c} <- violations do
          assert_received {[:relay, :integrity, :violation], %{violations: ^n}, %{check: ^c}}
        end
      end
    end)
  end

  test "TN-16: a polymorphic audit target that points nowhere is an orphan" do
    committed(fn ->
      tenant = tenant!()

      scoped(tenant.id, "live", fn ->
        rows!(
          "SELECT relay_fn.audit_append($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
          [Relay.Id.generate(), "test.orphaned" | actor()] ++
            ["delivery", Relay.Id.to_string(Relay.Id.generate()), nil, nil, nil, digest()]
        )
      end)

      assert {:ok, %{"violations" => violations}} = IntegrityTask.check()
      assert Enum.any?(violations, &(&1["table"] == "audit_log" and &1["violations"] > 0))
    end)
  end
end
