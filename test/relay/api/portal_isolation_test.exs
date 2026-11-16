defmodule Relay.Api.PortalIsolationTest do
  use Relay.DataCase, async: false

  alias RelayTest.Api
  alias RelayTest.PortalIsolation, as: Portal
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine

  setup do
    previous = WebhookEngine.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    a = TenantFixture.tenant!()
    b = TenantFixture.tenant!()
    for scope <- [a.live, a.test, b.live], do: unlimited!(scope)

    %{
      owner: Portal.world!(a.live),
      intruders: [
        {"of another consumer", Portal.world!(a.live)},
        {"of another tenant", Portal.world!(b.live)},
        {"of the test environment", Portal.world!(a.test)}
      ]
    }
  end

  # API-50
  defp unlimited!(scope) do
    change = %{
      key: "api.rate.burst",
      value: %{"weight" => 1_000_000, "window_seconds" => 1},
      expected_version: nil,
      record_digest: TenantFixture.digest()
    }

    {:ok, _} = Relay.Tenancy.put_setting(scope, change, TenantFixture.actor())
  end

  defp operations, do: Portal.operations(RelayWeb.Router)
  defp named, do: Enum.filter(operations(), &(Portal.parameters(&1) != []))
  defp lists, do: Enum.filter(operations(), &(Portal.parameters(&1) == [] and &1.method == "GET"))

  defp assert_missing(conn, operation, why) do
    assert conn.status == 404, "#{operation.id} #{why}: #{conn.status} #{conn.resp_body}"
    Api.assert_contract(conn)
    body = Jason.decode!(conn.resp_body)
    assert body["code"] =~ ~r/\Awebhook_(endpoint|message|attempt)_not_found\z/
  end

  defp snapshot(world) do
    endpoint = "/v1/portal/webhook_endpoints/" <> world["webhook_endpoint_id"]
    message = "/v1/portal/webhook_messages/" <> world["webhook_message_id"]

    %{
      endpoint: Jason.decode!(Portal.request(:get, endpoint, world.token).resp_body),
      message: Jason.decode!(Portal.request(:get, message, world.token).resp_body),
      endpoints:
        Jason.decode!(Portal.request(:get, "/v1/portal/webhook_endpoints", world.token).resp_body)
    }
  end

  describe "WH-47 TN-16 API-76 portal isolation" do
    test "WH-47, TN-16: the generator covers every mounted portal operation and names what it lacks" do
      for operation <- operations() do
        assert Portal.gaps(operation) == [],
               "the router mounts #{operation.id}; add its fixture or body to RelayTest.PortalIsolation"
      end

      assert length(operations()) == 16
    end

    test "WH-47, TN-16, API-76: a token of one consumer never reads or changes another consumer's endpoint, message or attempt",
         %{owner: owner, intruders: intruders} do
      before = snapshot(owner)
      assert before.endpoint["id"] == owner["webhook_endpoint_id"]
      assert before.message["id"] == owner["webhook_message_id"]

      for {why, intruder} <- intruders, operation <- named() do
        conn = Portal.call(operation, Portal.path(operation, owner), intruder.token)
        assert_missing(conn, operation, why)
      end

      assert snapshot(owner) == before

      for operation <- named() do
        conn = Portal.call(operation, Portal.path(operation, owner), owner.token)

        assert conn.status in 200..499 and conn.status != 404,
               "#{operation.id}: the owner must find its own resource: #{conn.resp_body}"
      end
    end

    test "WH-47, INV-39: a list of the portal never shows another consumer's endpoints or messages",
         %{owner: owner, intruders: intruders} do
      for {why, intruder} <- intruders, operation <- lists() do
        conn = Portal.call(operation, operation.path, intruder.token)
        assert conn.status == 200, "#{operation.id} #{why}: #{conn.status} #{conn.resp_body}"
        Api.assert_contract(conn)

        for name <- ~w(webhook_endpoint_id webhook_message_id) do
          refute conn.resp_body =~ owner[name], "#{operation.id} #{why} shows #{name}"
        end
      end

      for {_why, intruder} <- intruders do
        path = "/v1/portal/webhook_messages?endpoint_id=" <> owner["webhook_endpoint_id"]
        assert Jason.decode!(Portal.request(:get, path, intruder.token).resp_body)["data"] == []
      end

      listed = Portal.request(:get, "/v1/portal/webhook_messages", owner.token)
      assert [%{"id" => id}] = Jason.decode!(listed.resp_body)["data"]
      assert id == owner["webhook_message_id"]
    end

    test "WH-47, WH-52: an endpoint the portal adds belongs to the consumer of the token, whatever the request names",
         %{owner: owner, intruders: [{_why, other} | _]} do
      body = %{"url" => "https://hooks.example.com/mine", "event_types" => []}
      created = Portal.request(:post, "/v1/portal/webhook_endpoints", other.token, body)
      assert created.status == 201, created.resp_body
      Api.assert_contract(created)
      endpoint = Jason.decode!(created.resp_body)
      assert endpoint["consumer_id"] == other.consumer_id
      assert endpoint["consumer"] == other.consumer_key
      assert endpoint["use"] == "destination"

      for field <- [%{"consumer" => owner.consumer_key}, %{"consumer_id" => owner.consumer_id}] do
        extra = Map.merge(body, field)
        refused = Portal.request(:post, "/v1/portal/webhook_endpoints", other.token, extra)
        assert refused.status == 422, refused.resp_body
        assert Jason.decode!(refused.resp_body)["code"] == "unknown_field"
      end

      listed = Portal.request(:get, "/v1/portal/webhook_endpoints", owner.token)
      assert [%{"id" => id}] = Jason.decode!(listed.resp_body)["data"]
      assert id == owner["webhook_endpoint_id"]
    end

    test "WH-47, API-10: an idempotency key of one consumer never replays to another", ctx do
      %{owner: owner, intruders: [{_why, other} | _]} = ctx
      key = [{"idempotency-key", "portal-shared-key-0001"}]
      body = %{"url" => "https://hooks.example.com/shared", "event_types" => []}

      first = Portal.request(:post, "/v1/portal/webhook_endpoints", owner.token, body, key)
      second = Portal.request(:post, "/v1/portal/webhook_endpoints", other.token, body, key)
      again = Portal.request(:post, "/v1/portal/webhook_endpoints", owner.token, body, key)

      assert first.status == 201 and second.status == 201 and again.status == 201
      assert Plug.Conn.get_resp_header(second, "idempotency-replayed") == []
      assert Plug.Conn.get_resp_header(again, "idempotency-replayed") == ["true"]
      assert again.resp_body == first.resp_body
      assert Jason.decode!(second.resp_body)["consumer_id"] == other.consumer_id
      refute Jason.decode!(second.resp_body)["id"] == Jason.decode!(first.resp_body)["id"]
    end
  end
end
