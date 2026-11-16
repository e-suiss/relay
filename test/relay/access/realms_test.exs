defmodule Relay.Access.RealmsTest do
  use Relay.DataCase, async: false

  alias Relay.Access.Cache
  alias Relay.Access.Client
  alias Relay.Access.Clients
  alias Relay.Operators.Access.Http
  alias RelayTest.FakeAccess
  alias RelayTest.TenantFixture

  @token_endpoint FakeAccess.issuer() <> "/oauth2/token"

  setup do
    :ok = FakeAccess.install!()
    :ok = Clients.reset()
    :ok = Cache.forget(:_)
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
      refute_received {:fake_access, :token, _jkt, _form}

      unknown = "tnt_unknown" <> FakeAccess.random()
      assert {:error, :not_found} = Relay.Access.tenant_snapshot(unknown)
    end

    test "E-102: a client credentials grant without a resource never reaches Access" do
      assert {:error, %Relay.Error{code: :access_invalid_target}} =
               Client.token(@token_endpoint, grant_type: "client_credentials")

      refute_received {:fake_access, :nonce, :token}
      refute_received {:fake_access, :token, _jkt, _form}
    end

    test "E-102: a service token names its product and is DPoP-bound after one nonce challenge" do
      jkt = relay_jkt()
      form = [grant_type: "client_credentials", resource: "app_work"]

      assert {:ok, %{"token_type" => "DPoP"}} = Client.token(@token_endpoint, form)
      assert_received {:fake_access, :nonce, :token}

      assert_received {:fake_access, :token, ^jkt, %{"resource" => "app_work"} = sent}
      assert sent["grant_type"] == "client_credentials"
    end

    test "E-100: the public JWK of the Access client key is printed for its registration" do
      {:ok, jwk} = Client.public_jwk()
      printed = ExUnit.CaptureIO.capture_io(fn -> :ok = Client.print_client_key() end)
      assert Jason.decode!(printed) == Map.merge(jwk, %{"alg" => "ES256", "use" => "sig"})
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
