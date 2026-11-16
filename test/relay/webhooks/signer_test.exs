defmodule Relay.Webhooks.SignerTest do
  use ExUnit.Case, async: false

  alias Relay.Redacted
  alias Relay.Webhooks.Profile
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

  describe "WH-5 key text forms" do
    test "WH-5: a shown secret is whsec_ and the base64 of its 32 bytes, as the profile parses it" do
      text = Signer.secret(<<4::256>>)
      assert text == "whsec_" <> Base.encode64(<<4::256>>)
      assert {:ok, {:hmac, secret}} = Profile.parse_key(text)
      assert Redacted.expose(secret) == <<4::256>>
      assert Signer.scheme("v1a") == {:ok, :v1a}
      assert Signer.scheme("v1") == {:ok, :v1}
      assert Signer.scheme("v2") == :error
    end
  end

  describe "WH-5 WH-6 TN-32 the key store signer" do
    test "WH-5, TN-32: a v1a private key is never in the VM: only the label of its key store object is sealed and stored",
         %{scope: scope} do
      assert {:ok, key} = KeyStore.generate(scope, :v1a)
      assert %{scheme: "v1a", secret: nil, public_key: <<_::256>> = public} = key
      assert "sealed:relay-webhook-" <> id = key.secret_ct
      assert id == Relay.Id.to_string(key.id)

      content = Profile.signed_content("evt_1", 10, "{}")
      assert {:ok, [{:v1a, signature}]} = KeyStore.sign(scope, [stored(key)], content)
      assert :crypto.verify(:eddsa, :none, content, signature, [public, :ed25519])
      assert Profile.parse_key(Profile.public_key_text(public)) == {:ok, {:ed25519, public}}

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

      assert {:ok, [token]} = KeyStore.sign(scope, [stored(key)], "evt_2.11.{}")
      assert token == Profile.hmac_token(secret, "evt_2", 11, "{}")
    end

    test "WH-6: during an overlap the signer returns one token per key, the new key's first", %{
      scope: scope
    } do
      {:ok, old} = KeyStore.generate(scope, :v1)
      {:ok, new} = KeyStore.generate(scope, :v1a)
      content = "evt_3.12.{}"

      assert {:ok, [{:v1a, signature}, {:v1, _mac}] = tokens} =
               KeyStore.sign(scope, [stored(new), stored(old)], content)

      assert :crypto.verify(:eddsa, :none, content, signature, [new.public_key, :ed25519])
      assert [_new, _old] = String.split(Profile.signature_header(tokens), " ")

      retired = %{stored(old) | "secret_ct" => nil}

      assert {:error, %Relay.Error{code: :signing_key_retired}} =
               KeyStore.sign(scope, [stored(new), retired], content)
    end
  end
end
