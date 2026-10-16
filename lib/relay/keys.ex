defmodule Relay.Keys do
  @moduledoc """
  Key store port. Provider signing keys, the regional KEK that wraps tenant data keys, and the audit checkpoint key live in a PKCS#11 token; code reaches them only through this module, and the configured implementation talks to the token through a separate OS process.
  """

  alias Relay.Error
  alias Relay.Redacted

  @typedoc "Signature algorithm: ES256 (APNs, VAPID), RS256 (FCM assertion), Ed25519 (audit checkpoint)."
  @type alg :: :es256 | :rs256 | :ed25519

  @typedoc "PKCS#11 object label of a key."
  @type label :: String.t()

  @typedoc "Public key: the uncompressed P-256 point, the 32-byte Ed25519 key, or the RSA modulus and exponent."
  @type public_key :: binary() | {modulus :: binary(), exponent :: binary()}

  @callback ping() :: :ok | {:error, Error.t()}
  @callback sign(alg(), label(), binary()) :: {:ok, binary()} | {:error, Error.t()}
  @callback public_key(alg(), label()) :: {:ok, public_key()} | {:error, Error.t()}
  @callback wrap(label(), binary(), Redacted.t()) :: {:ok, binary()} | {:error, Error.t()}
  @callback unwrap(label(), binary(), binary()) :: {:ok, Redacted.t()} | {:error, Error.t()}

  @algs [:es256, :rs256, :ed25519]
  @port_keys [:module, :token, :pin_file]

  # TN-63
  @doc "Supervised children of the key store: `Relay.Keys.Port` with its `:module`, `:token` and `:pin_file` configuration, on every node that configures it."
  @spec children() :: [{module(), keyword()}]
  def children do
    case Application.get_env(:relay, Relay.Keys.Port) do
      nil -> []
      opts -> [{Relay.Keys.Port, Keyword.take(opts, @port_keys)}]
    end
  end

  @doc "Configuration keys of `Relay.Keys.Port`."
  @spec port_config_keys() :: [atom()]
  def port_config_keys, do: @port_keys

  # TN-63
  @doc "Checks that the key store answers."
  @spec ping() :: :ok | {:error, Error.t()}
  def ping, do: impl().ping()

  # TN-28
  # TN-30
  # OP-63
  @doc "Signs `message` with the private key `label`. ES256 signatures are the 64-byte `R‖S` form used by JWS."
  @spec sign(alg(), label(), binary()) :: {:ok, binary()} | {:error, Error.t()}
  def sign(alg, label, message)
      when alg in @algs and is_binary(label) and label != "" and is_binary(message),
      do: impl().sign(alg, label, message)

  # TN-31
  @doc "Returns the public half of the key pair `label`."
  @spec public_key(alg(), label()) :: {:ok, public_key()} | {:error, Error.t()}
  def public_key(alg, label) when alg in @algs and is_binary(label) and label != "",
    do: impl().public_key(alg, label)

  # TN-27
  @doc "Wraps a data key under the KEK `label`, binding it to `aad`."
  @spec wrap(label(), binary(), Redacted.t()) :: {:ok, binary()} | {:error, Error.t()}
  def wrap(label, aad, data_key)
      when is_binary(label) and label != "" and is_binary(aad),
      do: impl().wrap(label, aad, data_key)

  @doc "Unwraps a data key wrapped by `wrap/3` with the same KEK and `aad`."
  @spec unwrap(label(), binary(), binary()) :: {:ok, Redacted.t()} | {:error, Error.t()}
  def unwrap(label, aad, wrapped)
      when is_binary(label) and label != "" and is_binary(aad) and is_binary(wrapped),
      do: impl().unwrap(label, aad, wrapped)

  defp impl, do: Application.fetch_env!(:relay, :keys)
end
