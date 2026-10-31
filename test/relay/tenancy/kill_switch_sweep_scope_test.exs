defmodule Relay.Tenancy.KillSwitchSweepScopeTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Tenancy.KillSwitch
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @operator %{kind: :installation_operator, ref: "ops@example"}
  @scopes ["publish", "read", "subscribers", "config", "kill_switch"]

  setup do
    tenant = TenantFixture.tenant!()
    access_client = FakeAccess.client!(tenant.live, @scopes)
    clients = "SELECT id FROM relay.api_clients WHERE access_client_id = $1"
    api_client_id = one(tenant.live, clients, [access_client])
    cli = Relay.ExternalId.encode("cli", api_client_id)
    token = RelayTest.Api.token(tenant.live, @scopes, api_client_id: cli)
    other = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    F.workflow!(tenant.live, token, "order-returned")
    %{scope: tenant.live, token: token, other: other, api_client_id: api_client_id}
  end

  defp one(scope, sql, params) do
    {:ok, [[value]]} =
      Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)

    value
  end

  defp accept!(token, workflow) do
    body = %{
      "workflow" => workflow,
      "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
      "data" => %{"order" => "A-1"}
    }

    accepted = F.body(F.request(:post, "/v1/events", token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [%{"id" => delivery}] = F.body(F.request(:get, path, token), 200)["data"]
    {:ok, delivery_id} = Relay.ExternalId.decode(delivery, ["dlv"])
    delivery_id
  end

  defp paused(scope, delivery_id) do
    one(scope, "SELECT pause_rule_id FROM relay.deliveries WHERE id = $1", [delivery_id])
  end

  defp engage!(scope, kind, ref) do
    spec = %{
      scope_kind: kind,
      scope: scope,
      scope_ref: ref,
      reason: "incident 9",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    }

    {:ok, %{result: :engaged, id: external}} = KillSwitch.engage(spec, @operator)
    {:ok, id} = Relay.ExternalId.decode(external, ["ksw"])
    id
  end

  describe "TN-40 (2) queue stop point by workflow and API client" do
    test "TN-40: a workflow kill switch engaged later pauses that workflow's pending deliveries",
         ctx do
      shipped = accept!(ctx.other, "order-shipped")
      returned = accept!(ctx.other, "order-returned")

      workflow_id =
        one(ctx.scope, "SELECT id FROM relay.workflows WHERE key = $1", ["order-shipped"])

      kill_switch_id = engage!(ctx.scope, :workflow, workflow_id)
      assert {1, false} = KillSwitch.sweep(ctx.scope, kill_switch_id)

      assert paused(ctx.scope, shipped) == "killswitch.off"
      assert paused(ctx.scope, returned) == nil
    end

    test "TN-40: an API client kill switch engaged later pauses that client's pending deliveries",
         ctx do
      own = accept!(ctx.token, "order-shipped")
      foreign = accept!(ctx.other, "order-shipped")

      kill_switch_id = engage!(ctx.scope, :api_client, ctx.api_client_id)
      assert {1, false} = KillSwitch.sweep(ctx.scope, kill_switch_id)

      assert paused(ctx.scope, own) == "killswitch.off"
      assert paused(ctx.scope, foreign) == nil
    end
  end
end
