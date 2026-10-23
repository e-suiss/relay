defmodule Relay.Keys do
  @moduledoc """
  Key store port. Provider signing keys, the regional KEK that wraps tenant data keys, the blind index HMAC keys, the secret fingerprint key, secret data objects and the audit checkpoint key live in a PKCS#11 token; code reaches them only through this module, and the configured implementation talks to the token through a separate OS process. Blind index keys are generated inside the token and never leave it: the HMAC is computed inside it.

  The installation's key labels are configured under `config :relay, Relay.Keys`: `:kek_label` names the region KEK and `:fingerprint_label` the secret fingerprint key.
  """

  alias Relay.Error
  alias Relay.Redacted

  @typedoc "Signature algorithm: ES256 (APNs, VAPID), RS256 (FCM assertion), Ed25519 (audit checkpoint)."
  @type alg :: :es256 | :rs256 | :ed25519

  @typedoc "PKCS#11 object label of a key."
  @type label :: String.t()

  @typedoc "Kind of secret key generated inside the token: AES-256 or a 256-bit HMAC-SHA256 key."
  @type key_kind :: :aes_256 | :hmac_sha256

  @typedoc "Public key: the uncompressed P-256 point, the 32-byte Ed25519 key, or the RSA modulus and exponent."
  @type public_key :: binary() | {modulus :: binary(), exponent :: binary()}

  @callback ping() :: :ok | {:error, Error.t()}
  @callback sign(alg(), label(), binary()) :: {:ok, binary()} | {:error, Error.t()}
  @callback public_key(alg(), label()) :: {:ok, public_key()} | {:error, Error.t()}
  @callback wrap(label(), binary(), Redacted.t()) :: {:ok, binary()} | {:error, Error.t()}
  @callback unwrap(label(), binary(), binary()) :: {:ok, Redacted.t()} | {:error, Error.t()}
  @callback hmac_sha256(label(), Redacted.t()) :: {:ok, <<_::256>>} | {:error, Error.t()}
  @callback read_secret(label()) :: {:ok, Redacted.t()} | {:error, Error.t()}
  @callback generate_key(key_kind(), label(), binary()) :: :ok | {:error, Error.t()}

  @algs [:es256, :rs256, :ed25519]
  @port_keys [:module, :token, :pin_file]
  @label_keys [:kek_label, :fingerprint_label]
  @key_kinds [:aes_256, :hmac_sha256]

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

  @doc "Configuration keys of `Relay.Keys`: the installation's key labels."
  @spec label_config_keys() :: [atom()]
  def label_config_keys, do: @label_keys

  # TN-67 (1)
  @doc "The label of the region KEK, from the installation configuration."
  @spec kek_label() :: {:ok, label()} | {:error, Error.t()}
  def kek_label, do: configured(:kek_label)

  # TN-67 (4)
  @doc "The label of the installation's secret fingerprint key, from the installation configuration."
  @spec fingerprint_label() :: {:ok, label()} | {:error, Error.t()}
  def fingerprint_label, do: configured(:fingerprint_label)

  defp configured(key) do
    case :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(key) do
      label when is_binary(label) and label != "" ->
        {:ok, label}

      _ ->
        {:error, Error.new(:key_store_config, "key label is not configured", %{key: key})}
    end
  end

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

  # TN-66 (1)
  # TN-33
  @doc "Computes HMAC-SHA256 of `message` inside the token under the secret key `label`; the key never leaves the token."
  @spec hmac_sha256(label(), Redacted.t()) :: {:ok, <<_::256>>} | {:error, Error.t()}
  def hmac_sha256(label, message)
      when is_binary(label) and label != "" and is_struct(message, Redacted),
      do: impl().hmac_sha256(label, message)

  # TN-67 (1)
  # TN-66 (1)
  @doc "Generates a 256-bit secret key inside the token under `label` with the object identifier `id`; the key is sensitive, never extractable and usable only for its kind. A label already in use is refused with `:key_exists`."
  @spec generate_key(key_kind(), label(), binary()) :: :ok | {:error, Error.t()}
  def generate_key(kind, label, id)
      when kind in @key_kinds and is_binary(label) and label != "" and is_binary(id) and id != "",
      do: impl().generate_key(kind, label, id)

  # TN-26
  @doc "Reads the value of the secret data object `label`; the value comes back redacted."
  @spec read_secret(label()) :: {:ok, Redacted.t()} | {:error, Error.t()}
  def read_secret(label) when is_binary(label) and label != "", do: impl().read_secret(label)

  # TN-26
  # TN-27
  @doc "Builds the PKCS#11 URI (RFC 7512) of the object `label`."
  @spec uri(label()) :: String.t()
  def uri(label) when is_binary(label) and label != "",
    do: "pkcs11:object=" <> URI.encode(label, &URI.char_unreserved?/1)

  @doc "Returns the object label of a PKCS#11 URI (RFC 7512). A URI that carries a PIN is refused, and so is one without an object label."
  @spec label(String.t()) :: {:ok, label()} | {:error, Error.t()}
  def label("pkcs11:" <> rest) do
    {path, query} =
      case String.split(rest, "?", parts: 2) do
        [path, query] -> {path, query}
        [path] -> {path, ""}
      end

    attributes = attributes(path, ";") ++ attributes(query, "&")

    if Enum.any?(attributes, fn {name, _} -> name in ["pin-value", "pin-source"] end),
      do: {:error, Error.new(:invalid_key_ref, "a key reference must not carry a PIN")},
      else: object_label(for({"object", value} <- attributes, do: value))
  end

  def label(_ref), do: {:error, Error.new(:invalid_key_ref, "not a PKCS#11 URI")}

  defp object_label([label]) when is_binary(label) and label != "", do: {:ok, label}

  defp object_label(_labels),
    do: {:error, Error.new(:invalid_key_ref, "a key reference names one object")}

  defp attributes("", _separator), do: []

  defp attributes(text, separator) do
    for pair <- String.split(text, separator, trim: true) do
      case String.split(pair, "=", parts: 2) do
        [name, value] -> {String.downcase(name), decode(value)}
        [name] -> {String.downcase(name), ""}
      end
    end
  end

  defp decode(value) do
    URI.decode(value)
  rescue
    ArgumentError -> nil
  end

  # INV-55
  defp impl do
    :ok = Relay.NetworkGuard.check!(:keys)
    Application.fetch_env!(:relay, :keys)
  end
end
