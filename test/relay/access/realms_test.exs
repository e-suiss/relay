defmodule Relay.Access.RealmsTest do
  use Relay.DataCase, async: false

  alias Relay.Access.Cache
  alias Relay.Access.Client
  alias Relay.Access.Clients
  alias Relay.Operators.Access, as: OperatorAccess
  alias Relay.Operators.Access.Http
  alias RelayTest.FakeAccess
  alias RelayTest.TenantFixture

  @evaluation FakeAccess.issuer() <> "/access/v1/evaluation"
  @question %{"subject" => %{"type" => "user", "id" => "op-1"}, "action" => %{"name" => "read"}}

  setup do
    :ok = FakeAccess.install!()
    :ok = Clients.reset()
    true = :ets.delete_all_objects(Cache)
    tenant = TenantFixture.tenant!()
    client = FakeAccess.client!(tenant.test, ["read", "config"])
    %{tenant: tenant, access_tenant: tenant.attrs.access_tenant_id, client: client}
  end

  defp verify(token), do: Relay.Access.verify_server_token(token, FakeAccess.presented(token))

  defp relay_jkt do
    {:ok, %{"x" => x, "y" => y}} = Client.public_jwk()
    json = ~s({"crv":"P-256","kty":"EC","x":"#{x}","y":"#{y}"})
    Base.url_encode64(:crypto.hash(:sha256, json), padding: false)
  end

  defp forget_nonces, do: :ets.match_delete(Cache, {{:dpop_nonce, :_}, :_, :_})

  describe "E-96 tokens of the tenant realms" do
    test "E-96: a tenant API client's token from either realm of its tenant is accepted", ctx do
      claims = %{"scope" => "read"}

      for realm <- ["a", "b"] do
        token = FakeAccess.realm_token(ctx.access_tenant, ctx.client, realm, claims)
        assert {:ok, principal} = verify(token)
        assert principal.scope == ctx.tenant.test
        assert principal.scopes == ["read"]
      end
    end

    test "E-96: the snapshot and the realm keys are read once, then cached", ctx do
      tenant = ctx.access_tenant
      slug = tenant <> "-a"

      assert {:ok, _principal} = verify(FakeAccess.realm_token(tenant, ctx.client, "a"))
      assert_received {:fake_access, :snapshot, ^tenant}
      assert_received {:fake_access, :realm_keys, ^slug}

      assert {:ok, _principal} = verify(FakeAccess.realm_token(tenant, ctx.client, "a"))
      refute_received {:fake_access, :snapshot, _tenant}
      refute_received {:fake_access, :realm_keys, _slug}
    end

    test "E-96: a realm of another tenant, an unknown tenant and a key its realm does not publish are refused",
         ctx do
      other = FakeAccess.realm_issuer("tnt_" <> FakeAccess.random(), "a")
      foreign = FakeAccess.realm_token(ctx.access_tenant, ctx.client, "a", %{"iss" => other})
      unknown = FakeAccess.realm_token("tnt_unknown" <> FakeAccess.random(), ctx.client, "a")
      wrong_key = FakeAccess.realm_token(ctx.access_tenant, ctx.client, "a", %{}, "b")

      untenanted =
        FakeAccess.realm_token(ctx.access_tenant, ctx.client, "a", %{"access_tenant" => nil})

      for bad <- [foreign, unknown, wrong_key, untenanted] do
        assert {:error, %Relay.Error{code: :auth_invalid_token}} = verify(bad)
      end
    end

    test "E-96, E-93: a realm token is still checked for its audience, type and DPoP binding",
         ctx do
      other_audience = %{"aud" => "app_someone_else"}
      unbound = %{"cnf" => nil}

      for claims <- [other_audience, unbound] do
        token = FakeAccess.realm_token(ctx.access_tenant, ctx.client, "a", claims)
        assert {:error, %Relay.Error{code: :auth_invalid_token}} = verify(token)
      end

      token = FakeAccess.realm_token(ctx.access_tenant, ctx.client, "b")
      unproved = Keyword.delete(FakeAccess.presented(token), :proof)

      assert {:error, %Relay.Error{code: :auth_invalid_token}} =
               Relay.Access.verify_server_token(token, unproved)
    end

    test "E-96: a signature that does not verify under the realm key is refused", ctx do
      [header, claims, _signature] =
        ctx.access_tenant |> FakeAccess.realm_token(ctx.client, "a") |> String.split(".")

      [_header, _claims, signature] =
        ctx.access_tenant |> FakeAccess.realm_token(ctx.client, "b") |> String.split(".")

      forged = Enum.join([header, claims, signature], ".")
      assert {:error, %Relay.Error{code: :auth_invalid_token}} = verify(forged)
    end
  end

  describe "E-98 Relay's calls to Access" do
    test "E-100: the tenant snapshot is read with an RFC 7523 client assertion, without a token",
         ctx do
      tenant = ctx.access_tenant

      assert {:ok, %{"tenant" => ^tenant, "realms" => [_a, _b]}} =
               Relay.Access.tenant_snapshot(tenant)

      assert_received {:fake_access, :snapshot, ^tenant}
      refute_received {:fake_access, :token, _jkt, _grant}

      unknown = "tnt_unknown" <> FakeAccess.random()
      assert {:error, :not_found} = Relay.Access.tenant_snapshot(unknown)
    end

    test "E-98: a resource is called with a DPoP-bound token of a client assertion grant after one nonce challenge" do
      jkt = relay_jkt()

      assert {:ok, %{"decision" => true}} = Client.post(@evaluation, @question)
      assert_received {:fake_access, :nonce, :token}
      assert_received {:fake_access, :token, ^jkt, "client_credentials"}
      assert_received {:fake_access, :evaluation, _body}
      refute_received {:fake_access, :nonce, :resource}
    end

    test "E-98: a resource that asks for a fresh nonce is called once more with it" do
      assert {:ok, _answer} = Client.post(@evaluation, @question)
      assert_received {:fake_access, :token, _jkt, "client_credentials"}
      forget_nonces()

      assert {:ok, _answer} = Client.post(@evaluation, @question)
      assert_received {:fake_access, :nonce, :resource}
      refute_received {:fake_access, :token, _jkt, _grant}
    end

    test "E-98: a refused token is forgotten and the next call asks for a new one" do
      assert {:ok, _token} = Client.access_token()
      assert_received {:fake_access, :token, _jkt, "client_credentials"}
      stolen = Relay.Redacted.wrap("relay.x.y")
      :ok = Cache.put({Client, :access_token}, stolen, 60_000)

      assert {:error, %Relay.Error{code: :access_unreachable}} =
               Client.post(@evaluation, @question)

      assert {:ok, _answer} = Client.post(@evaluation, @question)
      assert_received {:fake_access, :token, _jkt, "client_credentials"}
    end

    test "E-100: the public JWK of the Access client key is printed for its registration" do
      {:ok, jwk} = Client.public_jwk()
      printed = ExUnit.CaptureIO.capture_io(fn -> :ok = Client.print_client_key() end)
      assert Jason.decode!(printed) == Map.merge(jwk, %{"alg" => "ES256", "use" => "sig"})
    end

    test "E-98, E-27: an AuthZEN decision is asked with Relay's DPoP-bound token" do
      previous = Application.get_env(:relay, OperatorAccess)

      discovery = %{
        "issuer" => FakeAccess.issuer(),
        "authorization_endpoint" => FakeAccess.issuer() <> "/oauth2/authorize",
        "token_endpoint" => FakeAccess.issuer() <> "/oauth2/token",
        "jwks" => FakeAccess.jwks(),
        "access_evaluation_endpoint" => FakeAccess.issuer() <> "/access/v1/evaluation"
      }

      config = Keyword.put(previous, :discovery, {Function, :identity, [{:ok, discovery}]})
      Application.put_env(:relay, OperatorAccess, config)
      on_exit(fn -> Application.put_env(:relay, OperatorAccess, previous) end)
      request = %{subject: "op-1", action: "tenant.suspend", resource: %{type: "tenant", id: "t"}}

      assert {:ok, %{decision: true, ref: "decision-1"}} = Http.evaluate(request)
      assert_received {:fake_access, :evaluation, %{"subject" => %{"id" => "op-1"}}}
    end
  end

  describe "E-98 operator tokens" do
    test "E-98: an operator CLI token is checked like a server token: Relay's client_id and DPoP",
         ctx do
      sub = "operator-" <> FakeAccess.random()
      token = FakeAccess.user_token(ctx.access_tenant, "app_cli", sub)

      assert {:ok, %{"sub" => ^sub}} =
               Http.verify_access_token(token, FakeAccess.presented(token))

      assert {:error, %Relay.Error{code: :auth_invalid_token}} =
               Http.verify_access_token(token, [])

      operator_audience = %{"aud" => "relay-operator-api"}
      legacy = FakeAccess.user_token(ctx.access_tenant, "app_cli", sub, operator_audience)

      assert {:error, %Relay.Error{code: :auth_invalid_token}} =
               Http.verify_access_token(legacy, FakeAccess.presented(legacy))
    end
  end
end
