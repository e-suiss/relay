defmodule Relay.Webhooks.Signer do
  @moduledoc """
  The signing port of the Suiss webhook profile (WH-4, WH-5, WH-6, TN-32). Every `https` endpoint has its own key, never shared between endpoints:

    * `v1a`, the default, is an Ed25519 key pair. The private key is generated inside the key store and leaves it only wrapped; it is unwrapped and used there, never in the VM. The public key is stored in the clear and can always be read.
    * `v1` is a 32-byte HMAC-SHA256 secret, for compatibility only. It is shown once, when the key is made, as `whsec_` and its base64, and cannot be read back.

  What is stored of either is sealed under the tenant's data key and opened only by the process that signs.

  The signed content is exactly `<webhook-id>.<webhook-timestamp>.<raw body>`. A signature token is `v1a,<base64 Ed25519 signature>` or `v1,<base64 HMAC-SHA256>`; the `webhook-signature` header is the tokens joined by a space. During a rotation overlap an endpoint has two keys and `c:sign/3` returns two tokens, the new key's first.

  The implementation is configured as `config :relay, Relay.Webhooks, signer: Module`; `Relay.Webhooks.Signer.KeyStore` is the default. Both callbacks reach the key store, so neither runs inside a transaction.
  """

  alias Relay.Error
  alias Relay.Redacted
  alias Relay.Scope

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

  @typedoc "A stored signing key as `Relay.Webhooks.signing_keys/2` reads it: a row with `\"scheme\"`, `\"secret_ct\"` and `\"secret_key_id\"`."
  @type key :: %{required(String.t()) => term()}

  @doc "Makes a signing key of `scheme` for an endpoint of `scope`."
  @callback generate(Scope.t(), scheme()) :: {:ok, generated()} | {:error, Error.t()}

  @doc "Signs `content` with each of `keys`, in their order, and returns one signature token per key."
  @callback sign(Scope.t(), [key(), ...], binary()) ::
              {:ok, [String.t(), ...]} | {:error, Error.t()}

  # WH-4
  @doc "The signed content of a delivery attempt: the webhook id, the Unix seconds of the attempt and the raw body, joined by dots."
  @spec content(String.t(), non_neg_integer(), binary()) :: binary()
  def content(webhook_id, timestamp, body)
      when is_binary(webhook_id) and is_integer(timestamp) and timestamp >= 0 and is_binary(body),
      do: IO.iodata_to_binary([webhook_id, ?., Integer.to_string(timestamp), ?., body])

  # WH-4
  @doc "A signature token: the scheme, a comma and the base64 of the signature."
  @spec token(scheme(), binary()) :: String.t()
  def token(:v1a, <<_::512>> = signature), do: "v1a," <> Base.encode64(signature)
  def token(:v1, <<_::256>> = mac), do: "v1," <> Base.encode64(mac)

  # WH-4
  @doc "The `webhook-signature` header of signature tokens: the tokens joined by a space."
  @spec header([String.t(), ...]) :: String.t()
  def header([_ | _] = tokens), do: Enum.join(tokens, " ")

  # WH-5
  @doc "The public form of an Ed25519 public key: `whpk_` and the base64 of its 32 bytes."
  @spec public_key(<<_::256>>) :: String.t()
  def public_key(<<_::256>> = key), do: "whpk_" <> Base.encode64(key)

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
