defmodule Relay.Access.ApiClientTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Access.Clients
  alias Relay.Access.Usage
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.TenantFixture
  alias RelayWeb.Auth.Access

  @domain "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'api_scope_check'"
  @set_status "SELECT * FROM relay_fn.api_client_set_status($1, $2, $3, $4, $5, $6, $7, $8)"

  setup do
    :ok = FakeAccess.install!()
    :ets.insert(Clients, {:generation, 0})
    tenant = TenantFixture.tenant!()
    client = FakeAccess.client!(tenant.test, ["read", "config"])
    %{tenant: tenant, access_tenant: tenant.attrs.access_tenant_id, client: client}
  end

  defp verify(token, opts \\ []),
    do: Relay.Access.verify_server_token(token, [audience: Access.audience(:server)] ++ opts)

  defp token(ctx, scope \\ "read config openid", claims \\ %{}),
    do: FakeAccess.server_token(ctx.access_tenant, ctx.client, scope, claims)

  defp clock(token, conn_fun \\ & &1) do
    :get
    |> Api.conn("/v1/virtual_clock", nil, [{"authorization", "Bearer " <> token}])
    |> conn_fun.()
    |> Api.call()
  end

  defp set_status(scope, client, status) do
    {:ok, actor} = Relay.Actor.new(:access, "access", "access")
    params = [client, status, "evt_status", TenantFixture.digest()] ++ Relay.Actor.params(actor)

    {:ok, [[result, generation]]} =
      Relay.Repo.in_scope(scope, fn _status -> Relay.Repo.query!(@set_status, params).rows end)

    {result, generation}
  end

  describe "API-71 API-42 API-43 server credentials" do
    test "API-71, API-42, API-48: a client credentials token maps to its client's tenant, environment and trace",
         ctx do
      assert {:ok, principal} = verify(token(ctx))
      assert principal.scope == ctx.tenant.test
      assert principal.subtenant_id == nil
      assert "cli_" <> _ = principal.api_client_id
      assert principal.certificate_bound == false
    end

    test "API-43, API-75: the granted scopes are the client's API-75 scopes the token carries",
         ctx do
      assert {:ok, %{scopes: ["config", "read"]}} = verify(token(ctx))
      assert {:ok, %{scopes: ["read"]}} = verify(token(ctx, "read publish"))
      assert {:ok, %{scopes: []}} = verify(token(ctx, "openid"))
    end

    test "API-71, E-25: a token for another audience, of an unknown client or tenant is refused",
         ctx do
      subscriber = token(ctx, "read", %{"aud" => Access.audience(:exchange)})
      unknown = FakeAccess.server_token(ctx.access_tenant, "app_unknown", "read")
      other = FakeAccess.server_token("acc_nobody", ctx.client, "read")
      bare = token(ctx, "read", %{"tenant_id" => nil})

      for bad <- [subscriber, unknown, other, bare] do
        assert {:error, %Relay.Error{code: :auth_invalid_token}} = verify(bad)
      end
    end

    test "API-71: an expired token is auth_expired_token", ctx do
      now = System.system_time(:second)
      expired = token(ctx, "read", %{"exp" => now - 120, "iat" => now - 400, "nbf" => now - 400})
      assert {:error, %Relay.Error{code: :auth_expired_token}} = verify(expired)
    end

    test "API-42, API-76 (2): a live client calling a test-only operation is auth_environment_mismatch",
         ctx do
      live = FakeAccess.client!(ctx.tenant.live, ["read"])
      conn = clock(FakeAccess.server_token(ctx.access_tenant, live, "read"))

      assert conn.status == 403
      Api.assert_contract(conn)
      assert Jason.decode!(conn.resp_body)["code"] == "auth_environment_mismatch"

      conn = clock(token(ctx))
      assert conn.status == 200
      Api.assert_contract(conn)
    end

    test "API-75: the api_scope domain is the OpenAPI ScopeName set" do
      [[definition]] = Relay.Repo.query!(@domain, []).rows
      names = ~r/'([a-z_]+)'/ |> Regex.scan(definition) |> Enum.map(&List.last/1)
      contract = Relay.Api.Contract.documents()["schemas"]["ScopeName"]["enum"]
      assert Enum.sort(names) == Enum.sort(contract)
    end
  end

  describe "API-44 TN-24 client lifecycle" do
    test "API-44, TN-24: a revoked or suspended client is rejected with auth_revoked_client",
         ctx do
      assert {:ok, _} = verify(token(ctx))

      {"changed", generation} = set_status(ctx.tenant.test, ctx.client, "suspended")
      :ok = Clients.advance(generation)
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token(ctx))

      {"changed", generation} = set_status(ctx.tenant.test, ctx.client, "active")
      :ok = Clients.advance(generation)
      assert {:ok, _} = verify(token(ctx))

      {"changed", generation} = set_status(ctx.tenant.test, ctx.client, "revoked")
      :ok = Clients.advance(generation)
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token(ctx))
      assert {"invalid_transition", nil} = set_status(ctx.tenant.test, ctx.client, "active")
    end

    test "API-44, TN-24 (5), TN-36: a revocation reaches a node through the generation signal",
         ctx do
      assert {:ok, _} = verify(token(ctx))
      {"changed", generation} = set_status(ctx.tenant.test, ctx.client, "revoked")

      assert {:ok, _} = verify(token(ctx))

      send(Process.whereis(Clients), {:relay_signal, Clients.topic(), {:seq, generation}})
      _ = :sys.get_state(Clients)

      assert Clients.generation() == generation
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token(ctx))
    end

    test "TN-10, INV-42, API-47: a suspended tenant is auth_tenant_suspended on the server API",
         ctx do
      change = %{
        status: "suspended",
        reason: "abuse",
        expected_version: nil,
        record_digest: TenantFixture.digest()
      }

      actor = TenantFixture.actor()

      assert {:ok, {:changed, _}} =
               Relay.Tenancy.set_tenant_status(ctx.tenant.live, change, actor)

      conn = clock(token(ctx))
      assert conn.status == 403
      Api.assert_contract(conn)
      assert Jason.decode!(conn.resp_body)["code"] == "auth_tenant_suspended"

      :ets.delete_all_objects(Clients)
      assert {:error, %Relay.Error{code: :auth_tenant_suspended}} = verify(token(ctx))
    end

    test "API-44, API-77 (1), API-77 (2): last use is written at most once a minute and the cap is reported",
         ctx do
      ip = {10, 9, 8, 7}
      assert {:ok, _} = verify(token(ctx), ip: ip)
      _written = Usage.flush()

      assert {:ok, %{clients: [client], count: 1, over_cap: false}} =
               Relay.Access.api_clients(ctx.tenant.test)

      assert %DateTime{} = client.last_used_at
      assert client.unused == false

      assert {:ok, _} = verify(token(ctx), ip: ip)
      assert Usage.flush() == 0
      refute Relay.Access.touch(ctx.tenant.test, client.id, ip)
      assert Relay.Access.client_limits() == %{per_environment: 50, unused_days: 90}

      for _ <- 1..50, do: FakeAccess.client!(ctx.tenant.test, ["read"])
      assert {:ok, %{count: 51, over_cap: true}} = Relay.Access.api_clients(ctx.tenant.test)
      assert {:ok, _} = verify(token(ctx))
    end
  end

  describe "API-41 API-48 certificate binding" do
    test "API-41, API-48: a certificate-bound token needs the connection's certificate", ctx do
      certificate = :crypto.strong_rand_bytes(300)
      thumbprint = Base.url_encode64(:crypto.hash(:sha256, certificate), padding: false)
      bound = token(ctx, "read", %{"cnf" => %{"x5t#S256" => thumbprint}})

      assert {:ok, %{certificate_bound: true}} = verify(bound, certificate: certificate)

      for certificate <- [nil, :crypto.strong_rand_bytes(300)] do
        assert {:error, %Relay.Error{code: :auth_invalid_token}} =
                 verify(bound, certificate: certificate)
      end
    end

    test "API-41: a tenant that requires mTLS refuses unbound tokens on the server API", ctx do
      change = %{key: "api.mtls_required", value: true, record_digest: TenantFixture.digest()}
      actor = TenantFixture.actor()
      assert {:ok, {:created, _}} = Relay.Tenancy.put_setting(ctx.tenant.test, change, actor)

      conn = clock(token(ctx))
      assert conn.status == 401
      Api.assert_contract(conn)

      certificate = :crypto.strong_rand_bytes(300)
      thumbprint = Base.url_encode64(:crypto.hash(:sha256, certificate), padding: false)
      bound = token(ctx, "read", %{"cnf" => %{"x5t#S256" => thumbprint}})
      peer = %{address: {10, 0, 0, 1}, port: 443, ssl_cert: certificate}

      conn = clock(bound, &Plug.Test.put_peer_data(&1, peer))
      assert conn.status == 200
      assert [_] = get_resp_header(conn, "request-id")
    end
  end

  describe "API-47 invalid tokens" do
    test "API-47, API-77 (3): invalid Access tokens are limited per client IP", ctx do
      ip = Api.ip()
      forged = token(ctx) <> "x"

      statuses = for _ <- 1..21, do: clock(forged, &Map.put(&1, :remote_ip, ip)).status

      assert Enum.take(statuses, 20) == List.duplicate(401, 20)
      assert List.last(statuses) == 429
    end
  end

  describe "API-25 subtenant selection" do
    test "API-25: the request selects a sub-tenant only within the client's binding", ctx do
      attrs = %{
        id: Relay.Id.generate(),
        access_organization_id: "org_1",
        name: "Shop",
        record_digest: TenantFixture.digest()
      }

      {:ok, {:created, subtenant, _}} =
        Relay.Tenancy.upsert_subtenant(ctx.tenant.test, attrs, TenantFixture.actor())

      named = Relay.ExternalId.encode("stn", subtenant)
      other = Relay.ExternalId.encode("stn", Relay.Id.generate())
      select = &Relay.Access.select_subtenant(ctx.tenant.test, &1, &2)

      assert select.(nil, nil) == {:ok, nil}
      assert select.(nil, named) == {:ok, subtenant}
      assert select.(subtenant, nil) == {:ok, subtenant}
      assert select.(subtenant, named) == {:ok, subtenant}

      for {bound, requested} <- [{subtenant, other}, {nil, other}, {nil, "stn_bad"}] do
        assert select.(bound, requested) == {:skipped, :scope_mismatch}
      end

      live = Relay.Access.select_subtenant(ctx.tenant.live, nil, named)
      assert live == {:skipped, :scope_mismatch}
    end
  end
end
