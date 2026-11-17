defmodule Relay.Access.EnvironmentsTest do
  use Relay.DataCase, async: false

  alias Relay.Access.Cache
  alias Relay.Access.Client
  alias Relay.Access.Clients
  alias Relay.Access.Environments
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

  describe "E-96 E-103 tokens of the tenant's Access environments" do
    test "E-96: a tenant API client's token from either Access environment of its tenant is accepted",
         ctx do
      claims = %{"scope" => "read"}

      for name <- ["a", "b"] do
        token = FakeAccess.environment_token(ctx.access_tenant, ctx.client, name, claims)
        assert {:ok, principal} = verify(token)
        assert principal.scope == ctx.tenant.test
        assert principal.scopes == ["read"]
      end
    end

    test "E-96: the snapshot and the Access environment keys are read once, then cached", ctx do
      tenant = ctx.access_tenant
      slug = tenant <> "-a"

      assert {:ok, _principal} = verify(FakeAccess.environment_token(tenant, ctx.client, "a"))
      assert_received {:fake_access, :snapshot, ^tenant}
      assert_received {:fake_access, :environment_keys, ^slug}

      assert {:ok, _principal} = verify(FakeAccess.environment_token(tenant, ctx.client, "a"))
      refute_received {:fake_access, :snapshot, _tenant}
      refute_received {:fake_access, :environment_keys, _slug}
    end

    test "E-103: the snapshot names the Access environments in environments, and their issuers are the /env/{slug} path issuers",
         ctx do
      tenant = ctx.access_tenant

      assert {:ok, %{"tenant" => ^tenant, "environments" => [a, b]} = snapshot} =
               Relay.Access.tenant_snapshot(tenant)

      refute Map.has_key?(snapshot, "realms")
      assert a["issuer"] == FakeAccess.issuer() <> "/env/" <> tenant <> "-a"
      assert Map.keys(a) == ["id", "issuer", "slug"]

      assert Relay.Access.access_environment_issuers(tenant) == {:ok, [a["issuer"], b["issuer"]]}

      unknown = "tnt_unknown" <> FakeAccess.random()
      assert Relay.Access.access_environment_issuers(unknown) == {:ok, :unknown}
    end

    test "E-103: a snapshot of an Access release before the rename, with realms, is read the same way" do
      tenant = "tnt_former" <> FakeAccess.random()
      scope = TenantFixture.tenant!(access_tenant_id: tenant).test
      client = FakeAccess.client!(scope, ["read"])

      assert {:ok, [first, _second]} = Relay.Access.access_environment_issuers(tenant)
      assert first == FakeAccess.environment_issuer(tenant, "a")

      token = FakeAccess.environment_token(tenant, client, "b", %{"scope" => "read"})
      assert {:ok, %{scope: ^scope}} = verify(token)

      assert Environments.listed(%{"tenant" => tenant, "environments" => []}, tenant) == {:ok, []}
      assert Environments.listed(%{"tenant" => tenant}, tenant) == :error
      assert Environments.listed(%{"tenant" => "tnt_x", "environments" => []}, tenant) == :error
    end

    test "E-96: an Access environment of another tenant, an unknown tenant and a key its Access environment does not publish are refused",
         ctx do
      tenant = ctx.access_tenant
      other = %{"iss" => FakeAccess.environment_issuer("tnt_" <> FakeAccess.random(), "a")}
      foreign = FakeAccess.environment_token(tenant, ctx.client, "a", other)
      stranger = "tnt_unknown" <> FakeAccess.random()
      unknown = FakeAccess.environment_token(stranger, ctx.client, "a")
      wrong_key = FakeAccess.environment_token(tenant, ctx.client, "a", %{}, "b")
      untenanted = %{"access_tenant" => nil}
      untenanted = FakeAccess.environment_token(tenant, ctx.client, "a", untenanted)

      for bad <- [foreign, unknown, wrong_key, untenanted] do
        assert {:error, %Relay.Error{code: :auth_invalid_token}} = verify(bad)
      end
    end

    test "E-96, E-93: an Access environment token is still checked for its audience, type and DPoP binding",
         ctx do
      other_audience = %{"aud" => "app_someone_else"}
      unbound = %{"cnf" => nil}

      for claims <- [other_audience, unbound] do
        token = FakeAccess.environment_token(ctx.access_tenant, ctx.client, "a", claims)
        assert {:error, %Relay.Error{code: :auth_invalid_token}} = verify(token)
      end

      token = FakeAccess.environment_token(ctx.access_tenant, ctx.client, "b")
      unproved = Keyword.delete(FakeAccess.presented(token), :proof)

      assert {:error, %Relay.Error{code: :auth_invalid_token}} =
               Relay.Access.verify_server_token(token, unproved)
    end

    test "E-96: a signature that does not verify under the Access environment key is refused",
         ctx do
      [header, claims, _signature] =
        ctx.access_tenant |> FakeAccess.environment_token(ctx.client, "a") |> String.split(".")

      [_header, _claims, signature] =
        ctx.access_tenant |> FakeAccess.environment_token(ctx.client, "b") |> String.split(".")

      forged = Enum.join([header, claims, signature], ".")
      assert {:error, %Relay.Error{code: :auth_invalid_token}} = verify(forged)
    end
  end

  describe "E-98 Relay's calls to Access" do
    test "E-100: the tenant snapshot is read with an RFC 7523 client assertion, without a token",
         ctx do
      tenant = ctx.access_tenant

      assert {:ok, %{"tenant" => ^tenant, "environments" => [_a, _b]}} =
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
