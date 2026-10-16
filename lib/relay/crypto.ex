defmodule Relay.Crypto do
  @moduledoc """
  Cryptographic helpers over the platform library (`:crypto`, OpenSSL based), one-shot calls only. Secret and signature comparisons are constant time. Keys may be passed wrapped in `Relay.Redacted`.
  """

  # TN-35
  @doc "Compares two binaries in constant time; binaries of different sizes are unequal."
  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(left, right)
      when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
      do: :crypto.hash_equals(left, right)

  def secure_compare(left, right) when is_binary(left) and is_binary(right), do: false

  @doc "Computes HMAC-SHA256 of `data` under `key`."
  @spec hmac_sha256(binary() | Relay.Redacted.t(), iodata()) :: <<_::256>>
  def hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, expose(key), data)

  @doc "Encrypts with AES-256-GCM in one call; returns the ciphertext and the 16-byte tag."
  @spec aes_256_gcm_encrypt(binary() | Relay.Redacted.t(), <<_::96>>, iodata(), iodata()) ::
          {binary(), <<_::128>>}
  def aes_256_gcm_encrypt(key, <<_::96>> = iv, plaintext, aad) do
    {ciphertext, <<_::128>> = tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, aes_key(key), iv, plaintext, aad, 16, true)

    {ciphertext, tag}
  end

  @doc "Decrypts and authenticates AES-256-GCM in one call."
  @spec aes_256_gcm_decrypt(
          binary() | Relay.Redacted.t(),
          <<_::96>>,
          binary(),
          iodata(),
          <<_::128>>
        ) ::
          {:ok, binary()} | :error
  def aes_256_gcm_decrypt(key, <<_::96>> = iv, ciphertext, aad, <<_::128>> = tag) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, aes_key(key), iv, ciphertext, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  defp aes_key(key) do
    <<_::256>> = key = expose(key)
    key
  end

  defp expose(key) do
    if Relay.Redacted.redacted?(key), do: Relay.Redacted.expose(key), else: key
  end
end
