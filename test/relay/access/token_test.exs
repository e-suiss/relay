defmodule Relay.Access.TokenTest do
  use ExUnit.Case, async: true

  alias Relay.Access.Jose
  alias Relay.Access.PlatformTenant
  alias Relay.Access.Token
  alias Relay.Access.Webhook

  @issuer "https://access.test"
  @audience "https://relay.test/v1"
  @pss [rsa_padding: :rsa_pkcs1_pss_padding, rsa_pss_saltlen: 32]

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp es256 do
    {<<4, x::binary-32, y::binary-32>>, private} = :crypto.generate_key(:ecdh, :secp256r1)
    jwk = %{"kty" => "EC", "crv" => "P-256", "kid" => "es", "x" => b64(x), "y" => b64(y)}
    {jwk, private}
  end

  defp ed25519 do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {%{"kty" => "OKP", "crv" => "Ed25519", "kid" => "ed", "x" => b64(public)}, private}
  end

  defp rsa(bits) do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} =
      private = :public_key.generate_key({:rsa, bits, 65_537})

    jwk = %{
      "kty" => "RSA",
      "kid" => "ps",
      "n" => b64(:binary.encode_unsigned(n)),
      "e" => b64(:binary.encode_unsigned(e))
    }

    {jwk, private}
  end

  defp keys(jwks) do
    {:ok, keys, _public} = Jose.public_keys(%{"keys" => jwks})
    keys
  end

  defp input(header, claims), do: b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))

  defp sign_es256(header, claims, private) do
    input = input(Map.merge(%{"alg" => "ES256", "kid" => "es"}, header), claims)
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64(<<r::256, s::256>>)
  end

  defp claims(extra \\ %{}) do
    now = System.system_time(:second)
    Map.merge(%{"iss" => @issuer, "aud" => @audience, "exp" => now + 300, "nbf" => now}, extra)
  end

  defp expectation, do: %{issuer: @issuer, audience: @audience, now: System.system_time(:second)}

  describe "API-71 signature and algorithms" do
    test "API-71: an ES256, an EdDSA and a PS256 token verify under their keys" do
      {es, es_private} = es256()
      {ed, ed_private} = ed25519()
      {ps, ps_private} = rsa(2048)
      keys = keys([es, ed, ps])

      assert {:ok, _} = Token.verify(sign_es256(%{}, claims(), es_private), keys, expectation())

      ed_input = input(%{"alg" => "EdDSA", "kid" => "ed"}, claims())
      ed_signature = :crypto.sign(:eddsa, :none, ed_input, [ed_private, :ed25519])
      assert {:ok, _} = Token.verify(ed_input <> "." <> b64(ed_signature), keys, expectation())

      ps_input = input(%{"alg" => "PS256", "kid" => "ps"}, claims())

      ps_signature = :public_key.sign(ps_input, :sha256, ps_private, @pss)

      assert {:ok, _} = Token.verify(ps_input <> "." <> b64(ps_signature), keys, expectation())
    end

    test "API-71: an unsigned token, another algorithm or a forged signature is refused" do
      {es, private} = es256()
      keys = keys([es])
      token = sign_es256(%{}, claims(), private)
      [header, payload, _signature] = String.split(token, ".")

      unsigned = b64(~s({"alg":"none","kid":"es"})) <> "." <> payload <> "."
      hs256 = b64(~s({"alg":"HS256","kid":"es"})) <> "." <> payload <> "." <> b64("mac")
      forged = header <> "." <> b64(Jason.encode!(claims(%{"sub" => "x"}))) <> "." <> "AAAA"

      for bad <- [unsigned, hs256, forged, "not-a-token"] do
        assert {:error, %Relay.Error{code: :auth_invalid_token}} =
                 Token.verify(bad, keys, expectation())
      end

      assert Jose.algorithms() == ["EdDSA", "ES256", "PS256"]
    end

    test "API-71: an RSA key below 2048 bits or a key set with private members is refused" do
      {small, _private} = rsa(1024)

      assert {:error, %Relay.Error{code: :access_keys_invalid}} =
               Jose.public_keys(%{"keys" => [small]})

      {es, _private} = es256()

      assert {:error, %Relay.Error{code: :access_keys_invalid}} =
               Jose.public_keys(%{"keys" => [Map.put(es, "d", b64("secret"))]})

      assert {:ok, [_key], public} = Jose.public_keys(%{"keys" => [Map.put(es, "x5u", "x")]})
      assert public == %{"keys" => [es]}
    end

    test "API-71: a token signed by a key the set does not hold names an unknown key" do
      {es, _private} = es256()
      {_other, other_private} = es256()

      token = sign_es256(%{"kid" => "rotated"}, claims(), other_private)
      assert {:error, :unknown_key} = Token.verify(token, keys([es]), expectation())
    end
  end

  describe "API-71 claims" do
    test "API-71: iss, aud, exp and nbf are checked with a tolerance of 60 seconds" do
      now = System.system_time(:second)
      ok = claims()

      assert {:ok, _} = Token.check(ok, expectation())
      assert {:ok, _} = Token.check(%{ok | "aud" => ["other", @audience]}, expectation())
      assert {:ok, _} = Token.check(%{ok | "exp" => now - 30}, expectation())
      assert {:ok, _} = Token.check(%{ok | "nbf" => now + 30}, expectation())

      for bad <- [
            %{ok | "iss" => "https://evil.test"},
            %{ok | "aud" => "https://relay.test/v1/operator"},
            %{ok | "nbf" => now + 120},
            Map.delete(ok, "exp")
          ] do
        assert {:error, %Relay.Error{code: :auth_invalid_token}} = Token.check(bad, expectation())
      end

      assert {:error, %Relay.Error{code: :auth_expired_token}} =
               Token.check(%{ok | "exp" => now - 61}, expectation())
    end

    test "API-47: issuer and audience comparisons take constant time over fixed-size digests" do
      assert Token.same?("https://access.test", "https://access.test")
      refute Token.same?("https://access.test", "https://access.tes")
      refute Token.same?(nil, "x")
    end
  end

  defp delivery(private, id, timestamp, body) do
    signature = :crypto.sign(:eddsa, :none, "#{id}.#{timestamp}.#{body}", [private, :ed25519])

    %{
      webhook_id: id,
      timestamp: Integer.to_string(timestamp),
      signature: "v1,bWFj v1a," <> Base.encode64(signature),
      raw_body: body
    }
  end

  describe "E-36 webhook profile" do
    test "E-36: a v1a signature under an Access Ed25519 key verifies within five minutes" do
      {ed, private} = ed25519()
      keys = keys([ed])
      now = System.system_time(:second)

      assert :ok = Webhook.verify(delivery(private, "msg_1", now, "{}"), keys, now)
      assert :ok = Webhook.verify(delivery(private, "msg_1", now - 290, "{}"), keys, now)

      tampered = %{delivery(private, "msg_1", now, "{}") | raw_body: ~s({"a":1})}
      old = delivery(private, "msg_1", now - 301, "{}")
      hmac_only = %{delivery(private, "msg_1", now, "{}") | signature: "v1,bWFj"}

      for bad <- [tampered, old, hmac_only] do
        assert {:error, %Relay.Error{code: :auth_invalid_token}} = Webhook.verify(bad, keys, now)
      end
    end
  end

  describe "E-11 platform tenant" do
    test "E-11, API-28: an Access event's dedup_key derives from its source and id (vector CE4)" do
      assert PlatformTenant.dedup_key("/access/events", "01j9zq3k4m5n6p7q8r9s0t1v2w") ==
               "ce:0c2eef367dc540300dc867eca53a11115061dd9f5ab04ea6b96d6d68eb0ff5be"
    end

    test "E-10, E-11, TN-9: an Access semantic event is security unless the producer declares a class" do
      assert Relay.Access.message_class("access", nil) == :security
      assert Relay.Access.message_class("access", :transactional) == :transactional
      assert Relay.Access.message_class("work", nil) == nil
      assert Relay.Access.message_class(nil, nil) == nil
    end
  end
end
