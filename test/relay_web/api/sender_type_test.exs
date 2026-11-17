defmodule RelayWeb.Api.SenderTypeTest do
  use Relay.DataCase, async: false

  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @scopes ["publish", "read", "subscribers", "config", "kill_switch"]

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    party = "agent-" <> TenantFixture.random()
    record = %{"name" => "Billing agent", "owner_ref" => "work:team-7"}
    record = Map.put(record, "access", %{"party" => party})
    F.body(F.request(:post, "/v1/agents", token, record), 201)
    client = FakeAccess.client!(tenant.live, ["agent:send"])
    access_tenant = tenant.attrs.access_tenant_id
    claims = %{"sub" => FakeAccess.pairwise(party)}
    agent = FakeAccess.server_token(access_tenant, client, "agent:send", claims)
    %{scope: tenant.live, token: token, agent: agent}
  end

  defp event(actor) do
    body = %{
      "workflow" => "order-shipped",
      "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
      "data" => %{"order" => "A-1"}
    }

    if actor, do: Map.put(body, "actor", actor), else: body
  end

  defp sender_type(ctx, token, actor) do
    accepted = F.body(F.request(:post, "/v1/events", token, event(actor)), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    F.body(F.request(:get, "/v1/notifications/" <> notification, ctx.token), 200)["sender_type"]
  end

  describe "PC-57 PC-2 sender type" do
    test "PC-57, PC-2: a send with agent credentials is always agent", ctx do
      assert sender_type(ctx, ctx.agent, nil) == "agent"
      assert sender_type(ctx, ctx.agent, %{"type" => "human"}) == "agent"
      assert sender_type(ctx, ctx.agent, %{"type" => "system"}) == "agent"
    end

    test "PC-57: another send defaults to system and keeps the type it declares", ctx do
      assert sender_type(ctx, ctx.token, nil) == "system"
      assert sender_type(ctx, ctx.token, %{"type" => "human"}) == "human"
      assert sender_type(ctx, ctx.token, %{"type" => "system"}) == "system"
    end

    test "AG-75, AG-48: another send cannot declare the type agent", ctx do
      conn = F.request(:post, "/v1/events", ctx.token, event(%{"type" => "agent"}))
      refused = F.body(conn, 422)

      assert refused["code"] == "validation_failed"
      assert [%{"pointer" => "/actor/type", "code" => "not_allowed"}] = refused["errors"]
    end

    test "AG-75: a credential marked as an agent's that names no agent record sends nothing",
         ctx do
      unbound = Api.token(ctx.scope, @scopes, api_client_id: "cli_agent", agent: true)
      conn = F.request(:post, "/v1/events", unbound, event(nil))

      assert F.body(conn, 403)["code"] == "auth_agent_inactive"
    end
  end
end
