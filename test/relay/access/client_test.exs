defmodule Relay.Access.ClientTest do
  use Relay.DataCase, async: false

  alias Relay.Access.Cache
  alias Relay.Access.Client
  alias Relay.Operators.Access, as: OperatorAccess
  alias Relay.Operators.Access.Http
  alias RelayTest.FakeAccess

  @resource FakeAccess.issuer() <> "/access/v1/fake/resource"

  setup do
    :ok = FakeAccess.install!()
    true = :ets.delete_all_objects(Cache)
    :ok
  end

  defp relay_jkt do
    {:ok, %{"x" => x, "y" => y}} = Client.public_jwk()
    json = ~s({"crv":"P-256","kty":"EC","x":"#{x}","y":"#{y}"})
    Base.url_encode64(:crypto.hash(:sha256, json), padding: false)
  end

  defp forget_nonces, do: :ets.match_delete(Cache, {{:dpop_nonce, :_}, :_, :_})

  describe "E-98 Relay's calls to Access" do
    test "E-98: a resource is read with a DPoP-bound token of a client assertion grant" do
      jkt = relay_jkt()

      assert {:ok, %{"resource" => "fake"}} = Client.get(@resource)
      assert_received {:fake_access, :nonce, :token}
      assert_received {:fake_access, :token, ^jkt, "client_credentials"}
      assert_received {:fake_access, :resource}
      refute_received {:fake_access, :nonce, :resource}

      missing = FakeAccess.issuer() <> "/access/v1/fake/missing"
      assert {:error, :not_found} = Client.get(missing)
      refute_received {:fake_access, :token, _jkt, _grant}
    end

    test "E-98: a resource that asks for a fresh nonce is called once more with it" do
      assert {:ok, _resource} = Client.get(@resource)
      assert_received {:fake_access, :token, _jkt, "client_credentials"}
      assert_received {:fake_access, :resource}
      forget_nonces()

      assert {:ok, _resource} = Client.get(@resource)
      assert_received {:fake_access, :nonce, :resource}
      assert_received {:fake_access, :resource}
      refute_received {:fake_access, :token, _jkt, _grant}
    end

    test "E-98: a refused token is forgotten and the next call asks for a new one" do
      assert {:ok, _token} = Client.access_token()
      assert_received {:fake_access, :token, _jkt, "client_credentials"}
      stolen = Relay.Redacted.wrap("relay.x.y")
      :ok = Cache.put({Client, :access_token}, stolen, 60_000)

      assert {:error, %Relay.Error{code: :access_unreachable}} = Client.get(@resource)

      assert {:ok, _resource} = Client.get(@resource)
      assert_received {:fake_access, :token, _jkt, "client_credentials"}
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
    test "E-98: an operator CLI token is checked like a server token: Relay's client_id and DPoP" do
      sub = "operator-" <> FakeAccess.random()
      tenant = "tnt_" <> FakeAccess.random()
      token = FakeAccess.user_token(tenant, "app_cli", sub)

      assert {:ok, %{"sub" => ^sub}} =
               Http.verify_access_token(token, FakeAccess.presented(token))

      assert {:error, %Relay.Error{code: :auth_invalid_token}} =
               Http.verify_access_token(token, [])

      operator_audience = %{"aud" => "relay-operator-api"}
      legacy = FakeAccess.user_token(tenant, "app_cli", sub, operator_audience)

      assert {:error, %Relay.Error{code: :auth_invalid_token}} =
               Http.verify_access_token(legacy, FakeAccess.presented(legacy))
    end
  end
end
