defmodule Relay.Webhooks.Destination.NatsJetstreamNkeyTest do
  use ExUnit.Case, async: true

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.NatsJetstream.Nkey

  defp raw(text) do
    {:ok, raw} = Base.decode32(text, padding: false)
    raw
  end

  describe "WH-17 NKey text form" do
    test "WH-17: the checksum is CRC-16/XMODEM" do
      assert Nkey.crc16("123456789") == 0x31C3
      assert Nkey.crc16("") == 0
    end

    test "WH-17: a user seed is the prefix, the key bytes and the checksum in base32" do
      bytes = :crypto.strong_rand_bytes(32)
      seed = Nkey.encode_seed(bytes)

      assert "SU" <> _rest = seed
      assert byte_size(seed) == 58
      assert <<149, 0, ^bytes::binary-size(32), crc::little-16>> = raw(seed)
      assert crc == Nkey.crc16(<<149, 0, bytes::binary>>)
    end

    test "WH-17: a seed is read back with the public key of its user" do
      bytes = :crypto.strong_rand_bytes(32)
      {expected, _private} = :crypto.generate_key(:eddsa, :ed25519, bytes)

      assert {:ok, %{public: public, seed: seed}} = Nkey.user(Nkey.encode_seed(bytes))
      assert Redacted.redacted?(seed)
      assert Redacted.expose(seed) == bytes
      assert public == Nkey.public(bytes)
      assert "U" <> _rest = public
      assert byte_size(public) == 56
      assert <<160, ^expected::binary-size(32), crc::little-16>> = raw(public)
      assert crc == Nkey.crc16(<<160, expected::binary>>)
    end

    test "WH-17: the signature of a nonce verifies with the public key" do
      bytes = :crypto.strong_rand_bytes(32)
      {:ok, %{public: public, seed: seed}} = Nkey.user(Nkey.encode_seed(bytes))
      <<160, key::binary-size(32), _crc::16>> = raw(public)

      signature = Nkey.sign(seed, "nonce-1")

      assert byte_size(signature) == 64
      assert :crypto.verify(:eddsa, :none, "nonce-1", signature, [key, :ed25519])
      refute :crypto.verify(:eddsa, :none, "nonce-2", signature, [key, :ed25519])
    end

    test "WH-17: a text that is not a user seed is not read as one" do
      bytes = :crypto.strong_rand_bytes(32)
      seed = Nkey.encode_seed(bytes)
      <<head::binary-size(10), char, tail::binary>> = seed
      damaged = head <> if(char == ?A, do: "B", else: "A") <> tail
      account = Base.encode32(<<144, 0, bytes::binary, 0, 0>>, padding: false)

      assert Nkey.user(damaged) == :error
      assert Nkey.user(Nkey.public(bytes)) == :error
      assert Nkey.user(account) == :error
      assert Nkey.user(String.downcase(seed)) == :error
      assert Nkey.user("tok-123") == :error
      assert Nkey.user("") == :error
      assert Nkey.user(nil) == :error
    end

    test "WH-19: the seed is not shown when the user is inspected" do
      bytes = :crypto.strong_rand_bytes(32)
      seed = Nkey.encode_seed(bytes)
      {:ok, user} = Nkey.user(seed)

      refute inspect(user) =~ seed
      refute inspect(user, limit: :infinity) =~ inspect(bytes, limit: :infinity)
    end
  end
end
