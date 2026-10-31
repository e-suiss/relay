defmodule Relay.Api.IsolationTest do
  use Relay.DataCase, async: false

  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.Isolation
  alias RelayTest.TenantFixture

  @routers [RelayWeb.Router, RelayTest.Api.Router]
  @scopes "publish read subscribers config kill_switch"
  @all ~w(publish read subscribers config kill_switch)

  setup do
    :ok = FakeAccess.install!()
    a = TenantFixture.tenant!()
    b = TenantFixture.tenant!()

    clients = [{:a_test, a, a.test}, {:a_live, a, a.live}, {:b_test, b, b.test}]

    tokens =
      Map.new(clients, fn {name, tenant, scope} ->
        client = FakeAccess.client!(scope, @all)
        {name, FakeAccess.server_token(tenant.attrs.access_tenant_id, client, @scopes)}
      end)

    %{a: a, b: b, tokens: tokens}
  end

  defp assert_not_found(conn, %{id: id} = operation, why) do
    if id in Isolation.upserts(),
      do: assert(conn.status == 201, "#{id} #{why}: #{conn.status} #{conn.resp_body}"),
      else: assert_missing(conn, operation, why)
  end

  defp assert_missing(conn, operation, why) do
    assert conn.status == 404, "#{operation.id} #{why}: #{conn.status} #{conn.resp_body}"
    Api.assert_contract(conn)
    body = Jason.decode!(conn.resp_body)
    assert body["code"] =~ ~r/_not_found\z/
    refute body["code"] == "route_not_found"
  end

  describe "TN-16 API-76 negative isolation" do
    test "TN-16, API-9: the generator covers every mounted resource operation and names what it lacks" do
      for router <- @routers, operation <- Isolation.operations(router) do
        assert Isolation.gaps(operation) == [],
               "#{inspect(router)} mounts #{operation.id}; add its fixture or body to RelayTest.Isolation"
      end

      assert Isolation.operations(RelayTest.Api.Router) != []
    end

    test "TN-16, TN-15, API-76, MD-18: another tenant's resource is 404 on every mounted operation",
         ctx do
      for router <- @routers, operation <- Isolation.operations(router) do
        path = Isolation.path(operation, ctx.b.test)

        refute Isolation.call(router, operation, path, ctx.tokens.b_test).status == 404,
               "#{operation.id}: the owner must find its own resource"

        conn = Isolation.call(router, operation, path, ctx.tokens.a_test)
        assert_not_found(conn, operation, "of another tenant")
      end
    end

    test "API-42, API-76, INV-38, INV-39, X-24: the other environment's resource is 404 too",
         ctx do
      for router <- @routers, operation <- Isolation.operations(router) do
        live = Isolation.path(operation, ctx.a.live)
        test = Isolation.path(operation, ctx.a.test)

        conn = Isolation.call(router, operation, live, ctx.tokens.a_test)
        assert_not_found(conn, operation, "of the live environment")
        conn = Isolation.call(router, operation, test, ctx.tokens.a_live)
        assert_not_found(conn, operation, "of the test environment")
      end
    end
  end
end
