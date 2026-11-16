defmodule Relay.Webhooks.Signer do
  @moduledoc """
  The signing port of the Suiss webhook profile (WH-4, WH-5, WH-6, TN-32). Every `https` endpoint has its own key, never shared between endpoints:

    * `v1a`, the default, is an Ed25519 key pair. The private key is generated inside the key store and never leaves it; every signature is made there, never in the VM. The public key is stored in the clear and can always be read.
    * `v1` is a 32-byte HMAC-SHA256 secret, for compatibility only. It is shown once, when the key is made, as `whsec_` and its base64, and cannot be read back.

  What is stored of either is sealed under the tenant's data key and opened only by the process that signs.

  The signed content, the tokens and the `webhook-signature` header are those of `Relay.Webhooks.Profile`, the one implementation of the profile. During a rotation overlap an endpoint has two keys and `c:sign/3` returns two tokens, the new key's first.

  The implementation is configured as `config :relay, Relay.Webhooks, signer: Module`; `Relay.Webhooks.Signer.KeyStore` is the default. Both callbacks reach the key store, so neither runs inside a transaction.
  """

  alias Relay.Error
  alias Relay.Redacted
  alias Relay.Scope
  alias Relay.Webhooks.Profile

  @type scheme :: :v1a | :v1

  @typedoc "A new signing key as it is stored: `secret` is the `whsec_` secret of a `v1` key, to be shown once, and `nil` for `v1a`."
  @type generated :: %{
          id: Relay.Id.t(),
          scheme: String.t(),
          public_key: <<_::256>> | nil,
          secret_ct: binary(),
          secret_key_id: Relay.Id.t(),
          secret: Redacted.t() | nil
        }

  @typedoc "A stored signing key as `Relay.Webhooks.signing_keys/2` reads it: a row with the columns `scheme`, `secret_ct` and `secret_key_id`."
  @type key :: %{required(String.t()) => term()}

  @doc "Makes a signing key of `scheme` for an endpoint of `scope`."
  @callback generate(Scope.t(), scheme()) :: {:ok, generated()} | {:error, Error.t()}

  @doc "Signs `content` with each of `keys`, in their order, and returns one profile token per key."
  @callback sign(Scope.t(), [key(), ...], binary()) ::
              {:ok, [Profile.token(), ...]} | {:error, Error.t()}

  # WH-5
  @doc "The form in which an HMAC secret is shown once: `whsec_` and the base64 of its bytes."
  @spec secret(<<_::256>>) :: String.t()
  def secret(<<_::256>> = secret), do: "whsec_" <> Base.encode64(secret)

  @doc "Casts a scheme from its text form."
  @spec scheme(term()) :: {:ok, scheme()} | :error
  def scheme("v1a"), do: {:ok, :v1a}
  def scheme("v1"), do: {:ok, :v1}
  def scheme(_other), do: :error
end
