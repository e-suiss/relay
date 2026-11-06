defmodule RelayWeb.Api.EventLinksTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @links [%{"rel" => "primary", "href" => "https://example.com/orders/1", "title" => "Order"}]

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    %{scope: tenant.live, token: token}
  end

  defp event(overrides) do
    Map.merge(
      %{
        "workflow" => "order-shipped",
        "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
        "data" => %{"order" => "A-1"}
      },
      overrides
    )
  end

  defp stored(scope) do
    sql = """
    SELECT e.interruption, p.links_ct IS NOT NULL FROM relay.events e
    JOIN relay.event_payloads p ON p.tenant_id = e.tenant_id AND p.environment = e.environment
      AND p.event_id = e.id AND p.created_at = e.payload_created_at
    ORDER BY e.created_at DESC, e.id DESC LIMIT 1
    """

    {:ok, [row]} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, []).rows end)
    row
  end

  describe "E-83 CH-65 event fields" do
    test "E-83, CH-65: the sender's interruption and encrypted links are stored with the event",
         ctx do
      body = event(%{"interruption" => "critical", "links" => @links})
      F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
      assert stored(ctx.scope) == ["critical", true]

      F.body(F.request(:post, "/v1/events", ctx.token, event(%{})), 202)
      assert stored(ctx.scope) == [nil, false]
    end

    test "E-83: a batch row keeps its own interruption and links", ctx do
      row = event(%{"interruption" => "passive", "links" => @links})
      F.body(F.request(:post, "/v1/events/batch", ctx.token, %{"events" => [row]}), 202)
      assert stored(ctx.scope) == ["passive", true]
    end

    test "E-83: a link that is not https is 422 link_scheme_not_allowed", ctx do
      links = [%{"rel" => "primary", "href" => "http://example.com/orders/1"}]
      conn = F.request(:post, "/v1/events", ctx.token, event(%{"links" => links}))
      assert F.body(conn, 422)["code"] == "link_scheme_not_allowed"
    end
  end
end
