defmodule Relay.Channels.Push.VapidTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Jwt
  alias Relay.Channels.Push.WebPush.Vapid

  @endpoint "https://fcm.googleapis.com/fcm/send/abc"
  @now 1_793_836_800

  setup do
    {:ok, key} = Vapid.key("vapid-app-1")
    {:ok, identity} = Vapid.identity("mailto:ops@example.com", [key])
    %{key: key, identity: identity}
  end

  defp verify(token, public_key) do
    [header, claims, signature] = String.split(token, ".")
    {:ok, <<r::256, s::256>>} = Jwt.decode64(signature)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :crypto.verify(:ecdsa, :sha256, header <> "." <> claims, der, [public_key, :secp256r1])
  end

  describe "CH-26 VAPID header" do
    test "CH-26: the header carries an ES256 token the public key verifies and the key", ctx do
      assert {:ok, header, _cache} =
               Vapid.authorization(ctx.identity, ctx.key, @endpoint, @now, %{})

      ["vapid t=" <> token, "k=" <> k] = String.split(header, ", ")
      assert Jwt.decode64(k) == {:ok, ctx.key.public_key}
      assert verify(token, ctx.key.public_key)

      [head | _] = String.split(token, ".")
      assert {:ok, json} = Jwt.decode64(head)
      assert Jason.decode!(json) == %{"alg" => "ES256", "typ" => "JWT"}

      assert {:ok, claims} = Jwt.peek_claims(token)
      assert claims["aud"] == "https://fcm.googleapis.com"
      assert claims["sub"] == "mailto:ops@example.com"
      assert Vapid.valid_claims?(claims, @endpoint, @now)
    end

    test "CH-26: exp is at most 24 hours ahead" do
      assert Vapid.lifetime() <= 24 * 3600
      claims = %{"aud" => "https://push.example", "sub" => "mailto:a@b.c"}
      endpoint = "https://push.example/x"
      refute Vapid.valid_claims?(Map.put(claims, "exp", @now + 24 * 3600 + 1), endpoint, @now)
      assert Vapid.valid_claims?(Map.put(claims, "exp", @now + 24 * 3600), endpoint, @now)
      refute Vapid.valid_claims?(Map.put(claims, "exp", @now), endpoint, @now)
    end

    test "CH-26: the audience is the endpoint's HTTPS origin" do
      assert Vapid.audience("https://Push.Example:443/a?b") == {:ok, "https://push.example"}
      assert Vapid.audience("https://push.example:8443/a") == {:ok, "https://push.example:8443"}
      assert {:error, %{code: :web_push_endpoint_invalid}} = Vapid.audience("http://push.example")
    end

    test "CH-26: a subject is mailto: or https:" do
      {:ok, key} = Vapid.key("vapid-app-2")
      assert {:ok, _identity} = Vapid.identity("https://example.com/contact", [key])
      assert {:error, %{code: :vapid_subject_invalid}} = Vapid.identity("ops@example.com", [key])
    end
  end

  describe "TN-31 token cache" do
    test "TN-31: tokens are cached per key and service, renewed an hour early", ctx do
      parent = self()

      signer = fn alg, label, message ->
        send(parent, :signed)
        Relay.Keys.sign(alg, label, message)
      end

      {:ok, first, cache} =
        Vapid.authorization(ctx.identity, ctx.key, @endpoint, @now, %{}, signer)

      assert_received :signed

      {:ok, again, cache} =
        Vapid.authorization(ctx.identity, ctx.key, @endpoint, @now + 3600, cache, signer)

      refute_received :signed
      assert again == first

      other = "https://updates.push.services.mozilla.com/wpush/v2/x"
      {:ok, _moz, cache} = Vapid.authorization(ctx.identity, ctx.key, other, @now, cache, signer)
      assert_received :signed
      assert map_size(cache) == 2

      due = @now + Vapid.lifetime() - 3600

      {:ok, renewed, _cache} =
        Vapid.authorization(ctx.identity, ctx.key, @endpoint, due, cache, signer)

      assert_received :signed
      assert renewed != first
    end

    test "TN-31: a key store failure is returned, never a token signed elsewhere", ctx do
      down = Relay.Error.new(:key_store_token, "down")
      signer = fn _alg, _label, _message -> {:error, down} end

      assert {:error, %{code: :key_store_token}} =
               Vapid.authorization(ctx.identity, ctx.key, @endpoint, @now, %{}, signer)
    end
  end

  describe "TN-31 rotation with two keys" do
    test "TN-31: new subscriptions take the new key, old ones keep theirs until retired", ctx do
      {:ok, new_key} = Vapid.key("vapid-app-1-v2")
      {:ok, rotated} = Vapid.rotate(ctx.identity, new_key)

      assert Vapid.select_key(rotated, nil) == {:ok, new_key}
      assert Vapid.select_key(rotated, ctx.key.public_key) == {:ok, ctx.key}
      assert Vapid.select_key(rotated, new_key.public_key) == {:ok, new_key}

      {:ok, retired} = Vapid.retire(rotated, ctx.key.label)

      assert {:error, %{code: :vapid_key_retired}} = Vapid.select_key(retired, ctx.key.public_key)

      assert {:error, %{code: :vapid_key_last}} = Vapid.retire(retired, new_key.label)
      assert {:error, %{code: :vapid_key_unknown}} = Vapid.retire(retired, "nope")
      assert {:error, %{code: :vapid_key_duplicate}} = Vapid.rotate(retired, new_key)
    end

    test "C-26: each channel identity has its own key" do
      {:ok, a} = Vapid.key("vapid-app-a")
      {:ok, b} = Vapid.key("vapid-app-b")
      assert a.public_key != b.public_key
    end
  end
end
