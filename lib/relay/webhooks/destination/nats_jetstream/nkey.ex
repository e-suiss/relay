defmodule Relay.Webhooks.Destination.NatsJetstream.Nkey do
  @moduledoc """
  NATS NKeys of a user (WH-17): Ed25519 keys in their text form. The module is pure.

  A key is written in base32 without padding: one or two prefix bytes that say what it is, the 32 key bytes and a CRC-16/XMODEM of both in little-endian order. A user seed starts with `SU`, the public key of a user with `U`. A server that asks for NKey authentication sends a nonce; the client answers with its public key and the Ed25519 signature of that nonce. The seed is a wrapped value from the moment it is read (WH-19).
  """

  import Bitwise

  alias Relay.Redacted

  @seed_prefix <<149, 0>>
  @user_prefix <<160>>
  @polynomial 0x1021

  @type user :: %{public: String.t(), seed: Redacted.t()}

  # WH-17
  @doc "Reads a user seed in its text form. A text that is not base32, has another prefix, another length or a wrong checksum is not a seed."
  @spec user(term()) :: {:ok, user()} | :error
  def user(text) when is_binary(text) do
    case Base.decode32(text, padding: false) do
      {:ok, <<149, 0, seed::binary-size(32), crc::little-16>>} -> checked(seed, crc)
      _other -> :error
    end
  end

  def user(_text), do: :error

  defp checked(seed, crc) do
    if crc16(@seed_prefix <> seed) == crc,
      do: {:ok, %{public: public(seed), seed: Redacted.wrap(seed)}},
      else: :error
  end

  @doc "The text form of the user seed that holds the 32 bytes `seed`."
  @spec encode_seed(<<_::256>>) :: String.t()
  def encode_seed(<<seed::binary-size(32)>>), do: text(@seed_prefix <> seed)

  @doc "The text form of the public key of the user whose seed bytes are `seed`."
  @spec public(<<_::256>>) :: String.t()
  def public(<<seed::binary-size(32)>>) do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    text(@user_prefix <> public)
  end

  # WH-17
  @doc "The Ed25519 signature of the server's nonce with the user's seed."
  @spec sign(Redacted.t(), binary()) :: binary()
  def sign(seed, nonce) when is_binary(nonce),
    do: :crypto.sign(:eddsa, :none, nonce, [Redacted.expose(seed), :ed25519])

  @doc "The CRC-16/XMODEM of `data`."
  @spec crc16(binary()) :: 0..0xFFFF
  def crc16(data) when is_binary(data), do: crc(data, 0)

  defp crc(<<>>, crc), do: crc
  defp crc(<<byte, rest::binary>>, crc), do: crc(rest, shift(bxor(crc, byte <<< 8), 8))

  defp shift(crc, 0), do: crc

  defp shift(crc, bits) when (crc &&& 0x8000) != 0,
    do: shift(bxor(crc <<< 1, @polynomial) &&& 0xFFFF, bits - 1)

  defp shift(crc, bits), do: shift(crc <<< 1 &&& 0xFFFF, bits - 1)

  defp text(raw), do: Base.encode32(raw <> <<crc16(raw)::little-16>>, padding: false)
end
