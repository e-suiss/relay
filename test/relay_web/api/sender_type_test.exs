defmodule RelayWeb.Api.SenderTypeTest do
  use Relay.DataCase, async: false

  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @scopes ["publish", "read", "subscribers", "config", "kill_switch"]

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    agent = Api.token(tenant.live, @scopes, api_client_id: "cli_agent", agent: true)
    %{scope: tenant.live, token: token, agent: agent}
  end

  defp sender_type(token, actor) do
    body = %{
      "workflow" => "order-shipped",
      "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
      "data" => %{"order" => "A-1"}
    }

    body = if actor, do: Map.put(body, "actor", actor), else: body
    accepted = F.body(F.request(:post, "/v1/events", token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    F.body(F.request(:get, "/v1/notifications/" <> notification, token), 200)["sender_type"]
  end

  describe "PC-57 PC-2 sender type" do
    test "PC-57, PC-2: a send with agent credentials is always agent", ctx do
      assert sender_type(ctx.agent, nil) == "agent"
      assert sender_type(ctx.agent, %{"type" => "human"}) == "agent"
      assert sender_type(ctx.agent, %{"type" => "system"}) == "agent"
    end

    test "PC-57: another send defaults to system and keeps the type it declares", ctx do
      assert sender_type(ctx.token, nil) == "system"
      assert sender_type(ctx.token, %{"type" => "human"}) == "human"
      assert sender_type(ctx.token, %{"type" => "agent"}) == "agent"
    end
  end
end
