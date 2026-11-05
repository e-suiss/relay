defmodule Relay.Channels.Push.WebPushEncryptionTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.WebPush.Encryption

  defp b64(text), do: text |> String.replace(" ", "") |> Base.url_decode64!(padding: false)

  @plaintext "When I grow up, I want to be a watermelon"
  @as_public "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
  @as_private "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  @ua_public "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @ua_private "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
  @salt "DGv6ra1nlYgDCS1FRnbzlw"
  @auth "BTBZMqHH6r4Tts7J_aSIgg"
  @header "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
  @legacy_dh "BNoRDbb84JGm8g5Z5CFxurSqsXWJ11ItfXEWYVLE85Y7CYkDjXsIEc4aqxYaQ1G8BqkXCJ6DPpDrWtdWj_mugHU"
  @ciphertext "8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ"

  describe "CH-3 RFC 8291 Appendix A" do
    test "CH-3: the intermediate values match the vector" do
      ecdh = :crypto.compute_key(:ecdh, b64(@ua_public), b64(@as_private), :secp256r1)
      assert ecdh == b64("kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs")

      keys = Encryption.keys(ecdh, b64(@auth), b64(@ua_public), b64(@as_public), b64(@salt))
      assert keys.prk_key == b64("Snr3JMxaHVDXHWJn5wdC52WjpCtd2EIEGBykDcZW32k")
      assert keys.ikm == b64("S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg")
      assert keys.prk == b64("09_eUZGrsvxChDCGRCdkLiDXrReGOEVeSCdCcPBSJSc")
      assert keys.cek == b64("oIhVW04MRdy2XN9CiKLxTg")
      assert keys.nonce == b64("4h_95klXJ5E_qnoN")
    end

    test "CH-3: encryption with the vector's key and salt yields the vector's body" do
      assert {:ok, body} =
               Encryption.encrypt(
                 @plaintext,
                 b64(@ua_public),
                 b64(@auth),
                 b64(@as_private),
                 b64(@salt)
               )

      assert byte_size(b64(@header)) == 86
      assert body == b64(@header) <> b64(@ciphertext)
    end

    test "CH-3: the user agent decrypts the vector's body" do
      body = b64(@header) <> b64(@ciphertext)
      assert Encryption.decrypt(body, b64(@ua_private), b64(@auth)) == {:ok, @plaintext}
    end

    test "CH-3: a tampered body or a wrong auth secret does not decrypt" do
      body = b64(@header) <> b64(@ciphertext)
      <<head::binary-100, byte, rest::binary>> = body
      tampered = head <> <<Bitwise.bxor(byte, 1)>> <> rest

      assert {:error, %{code: :web_push_undecryptable}} =
               Encryption.decrypt(tampered, b64(@ua_private), b64(@auth))

      assert {:error, %{code: :web_push_undecryptable}} =
               Encryption.decrypt(body, b64(@ua_private), :binary.copy(<<0>>, 16))
    end
  end

  describe "TN-31 ephemeral key" do
    test "TN-31: each message has a fresh key and salt and round-trips" do
      {ua_public, ua_private} = :crypto.generate_key(:ecdh, :secp256r1)
      auth = :crypto.strong_rand_bytes(16)

      assert {:ok, first} = Encryption.encrypt("hello", ua_public, auth)
      assert {:ok, second} = Encryption.encrypt("hello", ua_public, auth)

      <<salt1::binary-16, _rs1::32, 65, key1::binary-65, _rest1::binary>> = first
      <<salt2::binary-16, _rs2::32, 65, key2::binary-65, _rest2::binary>> = second
      assert salt1 != salt2
      assert key1 != key2

      assert Encryption.decrypt(first, ua_private, auth) == {:ok, "hello"}
      assert Encryption.decrypt(second, ua_private, auth) == {:ok, "hello"}
    end

    test "TN-31: the ephemeral private key is a P-256 scalar" do
      for _ <- 1..20 do
        key = Encryption.ephemeral_private()
        n = :binary.decode_unsigned(key)
        assert byte_size(key) == 32 and n > 0
        assert {_public, _private} = :crypto.generate_key(:ecdh, :secp256r1, key)
      end
    end
  end

  describe "CH-26 limits and legacy coding" do
    test "CH-26: the body never exceeds 4096 bytes and a longer message is refused" do
      {ua_public, _ua_private} = :crypto.generate_key(:ecdh, :secp256r1)
      auth = :crypto.strong_rand_bytes(16)
      max = Encryption.max_plaintext()

      assert {:ok, body} = Encryption.encrypt(:binary.copy("a", max), ua_public, auth)
      assert byte_size(body) == Encryption.max_body()

      assert {:error, %{code: :push_payload_too_large, details: %{limit: ^max}}} =
               Encryption.encrypt(:binary.copy("a", max + 1), ua_public, auth)
    end

    test "CH-26: a subscription key that is not a P-256 point is refused" do
      bad = <<4>> <> :binary.copy(<<1>>, 64)

      assert {:error, %{code: :web_push_subscription_invalid}} =
               Encryption.encrypt("x", bad, :binary.copy(<<0>>, 16))

      assert {:error, %{code: :web_push_subscription_invalid}} =
               Encryption.encrypt("x", <<1, 2, 3>>, :binary.copy(<<0>>, 16))
    end

    test "CH-26: the legacy aesgcm body of draft-ietf-webpush-encryption-04 is read" do
      body = b64("6nqAQUME8hNqw5J3kl8cpVVJylXKYqZOeseZG8UueKpA")
      salt = b64("lngarbyKfMoi9Z75xYXmkg")

      dh = b64(@legacy_dh)
      ua_private = b64("9FWl15_QUQAWDaD3k3l50ZBZQJ4au27F1V4F0uLSD_M")
      auth = b64("R29vIGdvbyBnJyBqb29iIQ")

      assert {:ok, "I am the walrus"} =
               Encryption.decrypt_aesgcm(body, salt, dh, ua_private, auth)

      assert {:error, %{code: :web_push_undecryptable}} =
               Encryption.decrypt_aesgcm(body, salt, dh, ua_private, :binary.copy(<<0>>, 16))
    end
  end
end
