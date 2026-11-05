defmodule Relay.Channels.Push.WebPush.Encryption do
  @moduledoc """
  Web Push message encryption (RFC 8291) in the `aes128gcm` content coding (RFC 8188): ECDH over P-256, HKDF-SHA-256 and AES-128-GCM from the platform library, in one record. The application server key pair is ephemeral: it is drawn fresh for every message, held only while the message is encrypted and never reaches the key store (TN-31). The legacy `aesgcm` coding is only read, never produced (CH-26, TN-35).

  An encrypted body is at most 4096 bytes, so a message carries at most 3993 bytes of plaintext; a longer one is refused, never cut.
  """

  alias Relay.Error

  @record_size 4096
  @max_body 4096
  @header_size 86
  @max_plaintext @max_body - @header_size - 1 - 16
  @order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  @typedoc "An uncompressed P-256 point."
  @type public_key :: <<_::520>>

  @typedoc "Derived values of one message."
  @type keys :: %{
          prk_key: <<_::256>>,
          ikm: <<_::256>>,
          prk: <<_::256>>,
          cek: <<_::128>>,
          nonce: <<_::96>>
        }

  # CH-26
  @doc "The largest encrypted body in bytes."
  @spec max_body() :: pos_integer()
  def max_body, do: @max_body

  # CH-26
  @doc "The largest plaintext in bytes that fits the largest body."
  @spec max_plaintext() :: pos_integer()
  def max_plaintext, do: @max_plaintext

  # CH-3
  # TN-31
  @doc "Encrypts `plaintext` for a subscription's `p256dh` key and `auth` secret with a fresh ephemeral key and salt from `Relay.Random`."
  @spec encrypt(binary(), public_key(), <<_::128>>) :: {:ok, binary()} | {:error, Error.t()}
  def encrypt(plaintext, ua_public, auth_secret),
    do: encrypt(plaintext, ua_public, auth_secret, ephemeral_private(), Relay.Random.bytes(16))

  # CH-3
  # TN-35
  @doc "Encrypts with the given application server private key and salt; the RFC 8291 Appendix A vector runs through this function."
  @spec encrypt(binary(), public_key(), <<_::128>>, <<_::256>>, <<_::128>>) ::
          {:ok, binary()} | {:error, Error.t()}
  def encrypt(
        plaintext,
        <<4, _::512>> = ua_public,
        <<_::128>> = auth,
        <<_::256>> = as_private,
        <<_::128>> = salt
      )
      when is_binary(plaintext) do
    with :ok <- fits(plaintext),
         {:ok, as_public} <- public(as_private),
         {:ok, ecdh} <- shared(ua_public, as_private) do
      %{cek: cek, nonce: nonce} = keys(ecdh, auth, ua_public, as_public, salt)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, [plaintext, 2], "", 16, true)

      {:ok, IO.iodata_to_binary([salt, <<@record_size::32, 65>>, as_public, ciphertext, tag])}
    end
  end

  def encrypt(_plaintext, _ua_public, _auth, _as_private, _salt),
    do: {:error, Error.new(:web_push_subscription_invalid, "the subscription keys are malformed")}

  # CH-3
  @doc "Derives the RFC 8291 intermediate values from the ECDH secret, the `auth` secret, both public keys and the salt."
  @spec keys(<<_::256>>, <<_::128>>, public_key(), public_key(), <<_::128>>) :: keys()
  def keys(ecdh, auth, ua_public, as_public, salt) do
    prk_key = hmac(auth, ecdh)
    ikm = expand(prk_key, ["WebPush: info", 0, ua_public, as_public], 32)
    prk = hmac(salt, ikm)

    %{
      prk_key: prk_key,
      ikm: ikm,
      prk: prk,
      cek: expand(prk, ["Content-Encoding: aes128gcm", 0], 16),
      nonce: expand(prk, ["Content-Encoding: nonce", 0], 12)
    }
  end

  # CH-26
  @doc "Decrypts an `aes128gcm` body as the user agent does, with the subscription's private key and `auth` secret. Only a single record is read."
  @spec decrypt(binary(), <<_::256>>, <<_::128>>) :: {:ok, binary()} | {:error, Error.t()}
  def decrypt(
        <<salt::binary-16, rs::32, 65, as_public::binary-65, record::binary>>,
        <<_::256>> = ua_private,
        <<_::128>> = auth
      )
      when rs >= 18 and byte_size(record) >= 17 and byte_size(record) <= rs do
    with {:ok, ua_public} <- public(ua_private),
         {:ok, ecdh} <- shared(as_public, ua_private) do
      %{cek: cek, nonce: nonce} = keys(ecdh, auth, ua_public, as_public, salt)
      size = byte_size(record) - 16
      <<ciphertext::binary-size(^size), tag::binary-16>> = record

      case :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, "", tag, false) do
        :error -> undecryptable()
        padded -> unpad_last(padded)
      end
    end
  end

  def decrypt(_body, _ua_private, _auth), do: undecryptable()

  # CH-26
  # TN-35
  @doc "Decrypts a legacy `aesgcm` body (draft-ietf-webpush-encryption-04) from the `salt` of its `Encryption` header and the `dh` key of its `Crypto-Key` header. Relay never produces this coding."
  @spec decrypt_aesgcm(binary(), <<_::128>>, public_key(), <<_::256>>, <<_::128>>) ::
          {:ok, binary()} | {:error, Error.t()}
  def decrypt_aesgcm(
        body,
        <<_::128>> = salt,
        <<4, _::512>> = as_public,
        <<_::256>> = ua_private,
        <<_::128>> = auth
      )
      when is_binary(body) and byte_size(body) >= 18 do
    with {:ok, ua_public} <- public(ua_private),
         {:ok, ecdh} <- shared(as_public, ua_private) do
      ikm = expand(hmac(auth, ecdh), ["Content-Encoding: auth", 0], 32)
      prk = hmac(salt, ikm)
      context = ["P-256", 0, <<65::16>>, ua_public, <<65::16>>, as_public]
      cek = expand(prk, ["Content-Encoding: aesgcm", 0, context], 16)
      nonce = expand(prk, ["Content-Encoding: nonce", 0, context], 12)
      size = byte_size(body) - 16
      <<ciphertext::binary-size(^size), tag::binary-16>> = body

      case :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, "", tag, false) do
        <<pad::16, _padding::binary-size(pad), plaintext::binary>> -> {:ok, plaintext}
        _other -> undecryptable()
      end
    end
  end

  def decrypt_aesgcm(_body, _salt, _as_public, _ua_private, _auth), do: undecryptable()

  # TN-31
  @doc "Draws a fresh P-256 private key from `Relay.Random`, in the range `1..n-1`."
  @spec ephemeral_private() :: <<_::256>>
  def ephemeral_private do
    key = Relay.Random.bytes(32)

    case :binary.decode_unsigned(key) do
      n when n > 0 and n < @order -> key
      _out_of_range -> ephemeral_private()
    end
  end

  defp fits(plaintext) when byte_size(plaintext) <= @max_plaintext, do: :ok

  defp fits(plaintext) do
    {:error,
     Error.new(:push_payload_too_large, "the Web Push message is too large", %{
       bytes: byte_size(plaintext),
       limit: @max_plaintext
     })}
  end

  defp public(private) do
    {public, _private} = :crypto.generate_key(:ecdh, :secp256r1, private)
    {:ok, public}
  rescue
    _error in [ErlangError, ArgumentError] ->
      {:error, Error.new(:web_push_key_invalid, "the private key is not a P-256 scalar")}
  end

  defp shared(public, private) do
    {:ok, :crypto.compute_key(:ecdh, public, private, :secp256r1)}
  rescue
    _error in [ErlangError, ArgumentError] ->
      {:error, Error.new(:web_push_subscription_invalid, "the public key is not a P-256 point")}
  end

  defp unpad_last(padded) do
    case padded |> :binary.bin_to_list() |> Enum.reverse() |> Enum.drop_while(&(&1 == 0)) do
      [2 | rest] -> {:ok, rest |> Enum.reverse() |> :binary.list_to_bin()}
      _other -> undecryptable()
    end
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp expand(prk, info, length) do
    <<out::binary-size(^length), _rest::binary>> = hmac(prk, [info, 1])
    out
  end

  defp undecryptable,
    do: {:error, Error.new(:web_push_undecryptable, "the message cannot be decrypted")}
end
