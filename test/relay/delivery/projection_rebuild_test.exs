defmodule Relay.Delivery.ProjectionRebuildTest do
  use Relay.MaintenanceCase, async: false

  alias Relay.Delivery.ProjectionRebuild

  setup do
    ref = make_ref()
    pid = self()

    :telemetry.attach_many(
      ref,
      [[:relay, :projection, :difference], [:relay, :projection, :rebuilt]],
      fn event, measurements, meta, _ -> send(pid, {event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    :ok
  end

  defp sweep_at(tenant_id, environment) do
    %{
      "sweep" => %{
        "started_at" => DateTime.to_iso8601(Relay.Clock.utc_now()),
        "scope" => %{"tenant_id" => Relay.Id.to_string(tenant_id), "environment" => environment},
        "after" => nil,
        "checked" => 0,
        "differing" => 0
      }
    }
  end

  test "OP-3: the weekly rebuild finds a projection that differs from its ledger" do
    committed(fn ->
      tenant = tenant!()

      {intact, corrupted} =
        scoped(tenant.id, "live", fn ->
          {recipient, _dek} = recipient!(tenant.keys["live"])
          {_, a} = pending_delivery!(recipient)
          {_, b} = pending_delivery!(recipient)
          {a, b}
        end)

      admin = Relay.SqlCase.connect(:admin)

      Postgrex.query!(admin, "UPDATE relay.deliveries SET late_event_count = 5 WHERE id = $1", [
        corrupted
      ])

      GenServer.stop(admin)

      state = sweep_at(tenant.id, "live")

      assert {:ok, %{"sweep" => sweep}, delay} =
               ProjectionRebuild.run(%{
                 name: "projection_rebuild",
                 node: "n",
                 fencing_token: 1,
                 state: state
               })

      assert delay > 0
      assert sweep["checked"] == 2
      assert sweep["differing"] == 1

      assert sweep["scope"] == %{
               "tenant_id" => Relay.Id.to_string(tenant.id),
               "environment" => "test"
             }

      assert_received {[:relay, :projection, :difference], %{count: 1}, %{environment: :live}}
      refute_received {[:relay, :projection, :difference], _, _}

      assert {:ok, []} =
               Relay.Delivery.rebuild_projection(Relay.Scope.new!(tenant.id, :live), intact)
    end)
  end

  test "OP-3: a finished sweep waits a week before the next one" do
    finished = DateTime.to_iso8601(Relay.Clock.utc_now())

    assert {:ok, %{"finished_at" => ^finished}, delay} =
             ProjectionRebuild.run(%{
               name: "projection_rebuild",
               node: "n",
               fencing_token: 1,
               state: %{"finished_at" => finished}
             })

    assert delay > 6 * 24 * 60 * 60_000
  end
end
