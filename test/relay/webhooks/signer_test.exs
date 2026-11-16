defmodule Relay.Webhooks.SignerTest do
  use ExUnit.Case, async: false

  alias Relay.Redacted
  alias Relay.Webhooks.Registration
  alias Relay.Webhooks.Signer
  alias Relay.Webhooks.Signer.KeyStore

  defmodule Sealer do
    @moduledoc false

    def seal(_scope, {"webhook_endpoint_keys", "secret_ct"}, value),
      do: {:ok, %{ct: "sealed:" <> Redacted.expose(value), key_id: <<7::128>>}}

    def open(_scope, {"webhook_endpoint_keys", "secret_ct"}, <<7::128>>, "sealed:" <> value),
      do: {:ok, Redacted.wrap(value)}
  end

  setup do
    previous = Application.get_env(:relay, Relay.Webhooks)
    Application.put_env(:relay, Relay.Webhooks, sealer: Sealer)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:relay, Relay.Webhooks, previous),
        else: Application.delete_env(:relay, Relay.Webhooks)
    end)

    %{scope: Relay.Scope.new!(Relay.Id.generate(), :live)}
  end

  defp stored(key) do
    %{
      "scheme" => key.scheme,
      "secret_ct" => key.secret_ct,
      "secret_key_id" => key.secret_key_id
    }
  end

  describe "WH-4 signed content and tokens" do
    test "WH-4: the signed content is exactly id.timestamp.body over the raw bytes" do
      assert Signer.content("msg_1", 1_700_000_000, ~s({"a": 1}\n)) ==
               ~s(msg_1.1700000000.{"a": 1}\n)

      assert Signer.content("msg_1", 0, "") == "msg_1.0."
      assert Signer.content("msg_1", 5, <<0, 255>>) == <<"msg_1.5.", 0, 255>>
    end

    test "WH-4: a token is the scheme, a comma and the base64 signature; the header joins tokens with a space" do
      assert Signer.token(:v1a, <<1::512>>) == "v1a," <> Base.encode64(<<1::512>>)
      assert Signer.token(:v1, <<2::256>>) == "v1," <> Base.encode64(<<2::256>>)
      assert Signer.header(["v1a,new", "v1a,old"]) == "v1a,new v1a,old"
      assert Signer.scheme("v1a") == {:ok, :v1a}
      assert Signer.scheme("v1") == {:ok, :v1}
      assert Signer.scheme("v2") == :error
    end

    test "WH-5: a public key is whpk_ and a shown secret whsec_, each with the base64 of 32 bytes" do
      assert Signer.public_key(<<3::256>>) == "whpk_" <> Base.encode64(<<3::256>>)
      assert Signer.secret(<<4::256>>) == "whsec_" <> Base.encode64(<<4::256>>)
    end
  end

  describe "WH-5 WH-6 TN-32 the key store signer" do
    test "WH-5, TN-32: a v1a private key is never in the VM: only the label of its key store object is sealed and stored",
         %{scope: scope} do
      assert {:ok, key} = KeyStore.generate(scope, :v1a)
      assert %{scheme: "v1a", secret: nil, public_key: <<_::256>> = public} = key
      assert "sealed:relay-webhook-" <> id = key.secret_ct
      assert id == Relay.Id.to_string(key.id)

      content = Signer.content("evt_1", 10, "{}")
      assert {:ok, ["v1a," <> encoded]} = KeyStore.sign(scope, [stored(key)], content)
      signature = Base.decode64!(encoded)
      assert :crypto.verify(:eddsa, :none, content, signature, [public, :ed25519])

      assert {:ok, other} = KeyStore.generate(scope, :v1a)
      refute other.public_key == public
    end

    test "WH-5: a v1 secret is 32 random bytes, shown once in the Standard Webhooks form", %{
      scope: scope
    } do
      assert {:ok, key} = KeyStore.generate(scope, :v1)
      assert %{scheme: "v1", public_key: nil} = key
      assert "whsec_" <> encoded = Redacted.expose(key.secret)
      secret = Base.decode64!(encoded)
      assert byte_size(secret) == 32
      refute inspect(key) =~ encoded

      assert {:ok, ["v1," <> mac]} = KeyStore.sign(scope, [stored(key)], "evt_2.11.{}")
      assert Base.decode64!(mac) == :crypto.mac(:hmac, :sha256, secret, "evt_2.11.{}")
    end

    test "WH-6: during an overlap the signer returns one token per key, the new key's first", %{
      scope: scope
    } do
      {:ok, old} = KeyStore.generate(scope, :v1)
      {:ok, new} = KeyStore.generate(scope, :v1a)
      content = "evt_3.12.{}"

      assert {:ok, ["v1a," <> signature, "v1," <> _mac]} =
               KeyStore.sign(scope, [stored(new), stored(old)], content)

      assert :crypto.verify(:eddsa, :none, content, Base.decode64!(signature), [
               new.public_key,
               :ed25519
             ])

      retired = %{stored(old) | "secret_ct" => nil}

      assert {:error, %Relay.Error{code: :signing_key_retired}} =
               KeyStore.sign(scope, [stored(new), retired], content)
    end
  end

  describe "WH-40 registration rules" do
    test "WH-40 (1), (2), (3): only https, an allowed port and no user information" do
      port = {:error, :port_not_allowed}
      user = {:error, :user_information}
      assert Registration.check("https://hooks.example.com/a?b=c", [443]) == :ok
      assert Registration.check("https://hooks.example.com:443/", [443]) == :ok
      assert Registration.check("https://[2001:db8::1]/", [443]) == :ok
      assert Registration.check("http://hooks.example.com/", [443]) == {:error, :not_https}
      assert Registration.check("ftp://hooks.example.com/", [443]) == {:error, :not_https}
      assert Registration.check("hooks.example.com", [443]) == {:error, :not_https}
      assert Registration.check("https://hooks.example.com:8443/", [443]) == port
      assert Registration.check("https://hooks.example.com:8443/", [443, 8443]) == :ok
      assert Registration.check("https://u:p@hooks.example.com/", [443]) == user
      assert Registration.check("https://", [443]) == {:error, :no_host}
      assert Registration.check("https://exa mple.com/", [443]) == {:error, :invalid}

      for reason <- [:invalid, :not_https, :user_information, :no_host, :port_not_allowed] do
        assert is_binary(Registration.explain(reason))
      end
    end
  end
end
