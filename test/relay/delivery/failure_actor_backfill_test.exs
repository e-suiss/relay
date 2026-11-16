defmodule Relay.Delivery.FailureActorBackfillTest do
  use Relay.MaintenanceCase, async: false

  @append "SELECT result FROM relay_fn.ledger_append($1, $2, NULL, 'provider_webhook', 'provider.reported', NULL, 'fake', NULL, now(), NULL, NULL, 'failed', 'permanent_target', NULL, NULL, NULL, NULL)"

  test "DS-4, OP-3: a missing failure source is filled from the ledger" do
    committed(fn ->
      tenant = tenant!()

      delivery =
        scoped(tenant.id, "live", fn ->
          {recipient, _dek} = recipient!(tenant.keys["live"])
          {_, delivery} = pending_delivery!(recipient)
          [["applied"]] = rows!(@append, [Relay.Id.generate(), delivery])
          delivery
        end)

      admin = Relay.SqlCase.connect(:admin)
      update = "UPDATE relay.deliveries SET failure_actor = NULL WHERE id = $1"
      Postgrex.query!(admin, update, [delivery])
      GenServer.stop(admin)

      scope = Relay.Scope.new!(tenant.id, :live)

      assert {:ok, [{"failure_actor", nil, "provider_webhook"}]} =
               Relay.Delivery.rebuild_projection(scope, delivery)

      assert {:ok, %{updated: 1}} = Relay.Delivery.backfill_failure_actors(scope, nil, 100)
      assert {:ok, []} = Relay.Delivery.rebuild_projection(scope, delivery)
      assert {:ok, %{updated: 0}} = Relay.Delivery.backfill_failure_actors(scope, nil, 100)
    end)
  end
end
