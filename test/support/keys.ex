defmodule RelayTest.Keys do
  @moduledoc "Key store for data layer tests: AES-256-GCM wrapping and HMAC-SHA256 under keys derived from their label, so tests agree on every key without a token. ES256 signing keys are P-256 key pairs derived from their label as well; there are no other signing keys and no secret data objects; key generation succeeds for any label."

  use Boundary, top_level?: true, deps: [Relay], exports: []

  @behaviour Relay.Keys

  alias Relay.Redacted

  @doc "The key behind a label."
  @spec secret(Relay.Keys.label()) :: <<_::256>>
  def secret(label), do: :crypto.hash(:sha256, "relay-test-key:" <> label)

  @impl Relay.Keys
  def ping, do: :ok

  @impl Relay.Keys
  def sign(:es256, label, message) do
    der = :crypto.sign(:ecdsa, :sha256, message, [es256(label), :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    {:ok, <<r::256, s::256>>}
  end

  def sign(_alg, _label, _message), do: not_found()

  @impl Relay.Keys
  def public_key(:es256, label) do
    {public, _private} = :crypto.generate_key(:ecdh, :secp256r1, es256(label))
    {:ok, public}
  end

  def public_key(_alg, _label), do: not_found()

  defp es256(label), do: :crypto.hash(:sha256, "relay-test-es256:" <> label)

  @impl Relay.Keys
  def wrap(label, aad, key) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        secret(label),
        iv,
        Redacted.expose(key),
        aad,
        16,
        true
      )

    {:ok, iv <> ciphertext <> tag}
  end

  @impl Relay.Keys
  def unwrap(label, aad, <<iv::binary-12, rest::binary>>) when byte_size(rest) >= 16 do
    size = byte_size(rest) - 16
    <<ciphertext::binary-size(^size), tag::binary-16>> = rest

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           secret(label),
           iv,
           ciphertext,
           aad,
           tag,
           false
         ) do
      :error -> integrity()
      key -> {:ok, Redacted.wrap(key)}
    end
  end

  def unwrap(_label, _aad, _wrapped), do: integrity()

  @impl Relay.Keys
  def hmac_sha256(label, message),
    do: {:ok, :crypto.mac(:hmac, :sha256, secret(label), Redacted.expose(message))}

  @impl Relay.Keys
  def read_secret(_label), do: not_found()

  @impl Relay.Keys
  def generate_key(_kind, _label, _id), do: :ok

  defp not_found, do: {:error, Relay.Error.new(:key_not_found, "key store: key not found")}

  defp integrity,
    do: {:error, Relay.Error.new(:key_integrity, "key store: wrapped key failed authentication")}
end
