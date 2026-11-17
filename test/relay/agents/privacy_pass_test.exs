defmodule Relay.Agents.PrivacyPassTest do
  use ExUnit.Case, async: true

  alias Relay.Agents
  alias Relay.Agents.PrivacyPass

  @vectors "conformance/vectors/privacy_pass_rfc9578.json"
           |> File.read!()
           |> Jason.decode!()
           |> Map.fetch!("vectors")

  defp hex(vector, field), do: Base.decode16!(vector[field], case: :lower)

  defp flip(binary, at) do
    <<head::binary-size(^at), byte, rest::binary>> = binary
    <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>
  end

  describe "AG-73 RFC 9578 type 0x0002 conformance vectors" do
    test "AG-73: every token of the RFC verifies under its issuer key and challenge" do
      assert length(@vectors) == 5

      for vector <- @vectors do
        token = hex(vector, "token")
        assert byte_size(token) == PrivacyPass.token_bytes()
        assert {:ok, key} = PrivacyPass.key(hex(vector, "issuer_public_key"))
        expected = PrivacyPass.challenge_digest(hex(vector, "token_challenge"))

        assert {:ok, spent} = PrivacyPass.verify(token, expected, [key])
        assert spent.digest == :crypto.hash(:sha256, token)
        assert spent.key_id == :crypto.hash(:sha256, hex(vector, "issuer_public_key"))
        assert binary_part(token, 2, 32) == hex(vector, "nonce")
      end
    end

    test "AG-73: the challenge without a redemption context is encoded as the RFC encodes it" do
      [_one, two, _three, four, _five] = @vectors

      assert PrivacyPass.challenge("issuer.example", "origin.example") ==
               hex(two, "token_challenge")

      assert PrivacyPass.challenge("issuer.example", "") == hex(four, "token_challenge")
    end

    test "AG-60, AG-73: a changed token, another challenge and an unknown key do not verify" do
      [vector | _rest] = @vectors
      token = hex(vector, "token")
      {:ok, key} = PrivacyPass.key(hex(vector, "issuer_public_key"))
      expected = PrivacyPass.challenge_digest(hex(vector, "token_challenge"))

      for at <- [0, 1, 2, 40, 70, 100, 353] do
        assert PrivacyPass.verify(flip(token, at), expected, [key]) == :error
      end

      other = PrivacyPass.challenge_digest(PrivacyPass.challenge("issuer.example", "relay"))
      assert PrivacyPass.verify(token, other, [key]) == :error
      assert PrivacyPass.verify(token, expected, []) == :error
      assert PrivacyPass.verify(binary_part(token, 0, 353), expected, [key]) == :error
      assert PrivacyPass.verify(token <> <<0>>, expected, [key]) == :error
      assert PrivacyPass.verify("", expected, [key]) == :error
    end

    test "AG-73: a token key that is not an RSA key of 2048 bits is not a key" do
      [vector | _rest] = @vectors
      der = hex(vector, "issuer_public_key")

      assert PrivacyPass.key("") == :error
      assert PrivacyPass.key(binary_part(der, 0, byte_size(der) - 1)) == :error
      assert PrivacyPass.key(der <> <<0>>) == :error
      assert PrivacyPass.key(<<0x30, 0x00>>) == :error
    end
  end

  describe "AG-60 AG-73 the token of a first contact" do
    test "AG-60, AG-73: a token is valid only for the issuer and origin it was issued for" do
      [_one, vector | _rest] = @vectors
      token = hex(vector, "token")

      issuer = %{
        issuer_name: "issuer.example",
        origin: "origin.example",
        token_keys: [hex(vector, "issuer_public_key")]
      }

      assert {:valid, %{digest: digest}} = Agents.first_contact_token(token, issuer)
      assert digest == :crypto.hash(:sha256, token)

      assert Agents.first_contact_token(token, %{issuer | origin: "relay.example"}) == :invalid
      assert Agents.first_contact_token(token, %{issuer | issuer_name: "other"}) == :invalid
      assert Agents.first_contact_token(token, %{issuer | token_keys: []}) == :invalid
      assert Agents.first_contact_token(token, %{issuer | token_keys: ["junk"]}) == :invalid
    end

    test "AG-73: without an issuer every token is invalid and no token is none" do
      [vector | _rest] = @vectors

      assert Agents.first_contact_token(hex(vector, "token"), nil) == :invalid
      assert Agents.first_contact_token(nil, nil) == :none
    end
  end

  describe "AG-69 trust label order" do
    test "AG-69: blocked comes before spam, spam before authenticated, then unauthenticated" do
      all = %{
        blocked: true,
        marked_spam: true,
        over_first_contact_rate: true,
        authenticated: true
      }

      assert Agents.trust_label(all) == :blocked
      assert Agents.trust_label(%{suspended: true, authenticated: true}) == :blocked
      assert Agents.trust_label(%{all | blocked: false}) == :spam
      assert Agents.trust_label(%{over_first_contact_rate: true, authenticated: true}) == :spam
      assert Agents.trust_label(%{marked_spam: true}) == :spam
      assert Agents.trust_label(%{authenticated: true}) == :authenticated
      assert Agents.trust_label(%{}) == :unauthenticated
    end
  end

  describe "AG-74 encrypted transport by region" do
    test "AG-74: the eu region carries encrypted envelopes only when its data set turns them on" do
      on = %{"regions" => [%{"region" => "eu", "person_to_person" => true}]}
      off = %{"regions" => [%{"region" => "eu", "person_to_person" => false}]}
      elsewhere = %{"regions" => [%{"region" => "tr", "person_to_person" => true}]}

      assert Agents.encrypted_transport("eu", nil) == :disabled
      assert Agents.encrypted_transport("eu", off) == :disabled
      assert Agents.encrypted_transport("eu", elsewhere) == :disabled
      assert Agents.encrypted_transport("eu", %{}) == :disabled
      assert Agents.encrypted_transport("eu", on) == :enabled
      assert Agents.encrypted_transport(:eu, on) == :enabled
    end

    test "AG-74: other regions carry them and the bundled version leaves the eu region off" do
      assert Agents.encrypted_transport("tr", nil) == :enabled
      assert Agents.encrypted_transport("us", nil) == :enabled

      bundled =
        "priv/datasets/encrypted_transport/v1.json" |> File.read!() |> Jason.decode!()

      assert Agents.encrypted_transport("eu", bundled) == :disabled
      assert Agents.encrypted_transport("tr", bundled) == :enabled
    end
  end
end
