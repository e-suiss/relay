defmodule Relay.Webhooks.Profile do
  @moduledoc """
  The Suiss webhook profile: the Standard Webhooks headers and signatures that Relay and Access share, so that one verifier accepts the events of both products (WH-4).

  A message carries `webhook-id` (the event id, the same for every attempt), `webhook-timestamp` (Unix seconds, renewed on every attempt, WH-7) and `webhook-signature`, a list of signatures separated by a space. The signed content is `<id>.<timestamp>.<raw body>` over the raw bytes of the body. A signature is `v1a,<base64>` (Ed25519, the default) or `v1,<base64>` (HMAC-SHA256, for compatibility only); during a key rotation overlap a message carries one signature for each key (WH-6).

  `verify/5` is the one verifier for outbound self-tests and for inbound webhooks that follow the profile (WH-49 (2), WH-50, WH-51). It takes the headers as they arrived and the body as the bytes that arrived, never a body that was parsed and serialised again, accepts the message if any signature verifies against any of the keys, compares HMAC signatures in constant time and refuses a timestamp outside the tolerance in either direction.

  The headers `webhook-event-type` and `webhook-attempt` are a convenience and are not signed: no security decision may rest on them (WH-9).

  Keys use the text forms of the profile: `whpk_<base64>` for an Ed25519 public key and `whsec_<base64>` for an HMAC secret. Signing with an Ed25519 private key is not done here; the key stays in the key store.
  """

  alias Relay.Crypto
  alias Relay.Redacted

  @id "webhook-id"
  @timestamp "webhook-timestamp"
  @signature "webhook-signature"
  @event_type "webhook-event-type"
  @attempt "webhook-attempt"

  @id_syntax ~r/\A[\x21-\x7E]{1,256}\z/
  @timestamp_syntax ~r/\A(?:0|[1-9][0-9]{0,14})\z/
  @other_scheme ~r/\Av[0-9][0-9a-z]{0,7},[A-Za-z0-9+\/=_-]+\z/

  @type scheme :: :v1a | :v1
  @type token :: {scheme(), binary()}
  @type key :: {:ed25519, <<_::256>>} | {:hmac, binary() | Redacted.t()}
  @type header :: {String.t(), String.t()}
  @type headers :: [{String.t(), term()}] | %{optional(String.t()) => term()}
  @type rejection ::
          :missing_header
          | :duplicate_header
          | :malformed_header
          | :timestamp_out_of_tolerance
          | :no_matching_signature
  @type verified :: %{id: String.t(), timestamp: non_neg_integer(), scheme: scheme()}

  # WH-4 (2)
  @doc "The names of the three signed headers."
  @spec header_names() :: [String.t(), ...]
  def header_names, do: [@id, @timestamp, @signature]

  # WH-9
  @doc "The names of the unsigned convenience headers. No security decision may rest on them."
  @spec unsigned_header_names() :: [String.t(), ...]
  def unsigned_header_names, do: [@event_type, @attempt]

  # WH-9
  @doc "The unsigned convenience headers of one attempt: the event type and the attempt number."
  @spec unsigned_headers(String.t(), pos_integer()) :: [header(), ...]
  def unsigned_headers(event_type, attempt)
      when is_binary(event_type) and is_integer(attempt) and attempt >= 1,
      do: [{@event_type, event_type}, {@attempt, Integer.to_string(attempt)}]

  # WH-4 (2)
  @doc "Whether a value can be a `webhook-id`: 1 to 256 visible ASCII characters."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_syntax, id)

  # WH-4 (3)
  @doc "The signed content of a message: `<id>.<timestamp>.<raw body>`, over the raw bytes of the body."
  @spec signed_content(String.t(), non_neg_integer(), binary()) :: binary()
  def signed_content(id, timestamp, raw_body)
      when is_binary(id) and is_integer(timestamp) and timestamp >= 0 and is_binary(raw_body),
      do: <<id::binary, ?., Integer.to_string(timestamp)::binary, ?., raw_body::binary>>

  # WH-4 (4)
  @doc "Wraps a raw signature as a token of its scheme: 64 bytes for `:v1a`, 32 bytes for `:v1`."
  @spec token(scheme(), binary()) :: token()
  def token(:v1a, <<_::512>> = signature), do: {:v1a, signature}
  def token(:v1, <<_::256>> = signature), do: {:v1, signature}

  # WH-4 (4)
  @doc "Signs a message with an HMAC secret and returns the `v1` token."
  @spec hmac_token(binary() | Redacted.t(), String.t(), non_neg_integer(), binary()) :: token()
  def hmac_token(secret, id, timestamp, raw_body),
    do: {:v1, Crypto.hmac_sha256(secret, signed_content(id, timestamp, raw_body))}

  # WH-4 (2)
  # WH-6
  @doc "The value of `webhook-signature` for one or more tokens, the newest key first."
  @spec signature_header([token(), ...]) :: String.t()
  def signature_header([_first | _rest] = tokens), do: Enum.map_join(tokens, " ", &encode/1)

  defp encode({:v1a, <<_::512>> = signature}), do: "v1a," <> Base.encode64(signature)
  defp encode({:v1, <<_::256>> = signature}), do: "v1," <> Base.encode64(signature)

  # WH-4 (2)
  # WH-7 (1)
  @doc "The three signed headers of one attempt."
  @spec headers(String.t(), non_neg_integer(), [token(), ...]) :: [header(), ...]
  def headers(id, timestamp, tokens) when is_binary(id) and is_integer(timestamp) do
    [
      {@id, id},
      {@timestamp, Integer.to_string(timestamp)},
      {@signature, signature_header(tokens)}
    ]
  end

  @doc "Parses the text form of a key: `whpk_<base64>` (Ed25519 public key) or `whsec_<base64>` (HMAC secret, at least 24 bytes; returned wrapped)."
  @spec parse_key(term()) :: {:ok, key()} | :error
  def parse_key("whpk_" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::256>> = public_key} -> {:ok, {:ed25519, public_key}}
      _other -> :error
    end
  end

  def parse_key("whsec_" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, secret} when byte_size(secret) >= 24 -> {:ok, {:hmac, Redacted.wrap(secret)}}
      _other -> :error
    end
  end

  def parse_key(_other), do: :error

  @doc "The published text form of an Ed25519 public key."
  @spec public_key_text(<<_::256>>) :: String.t()
  def public_key_text(<<_::256>> = public_key), do: "whpk_" <> Base.encode64(public_key)

  # WH-6
  @doc "Parses a `webhook-signature` value into its tokens. A token of a scheme this profile does not know is skipped; a token that is not well formed refuses the whole header."
  @spec parse_signature_header(term()) :: {:ok, [token()]} | {:error, :malformed_header}
  def parse_signature_header(value) when is_binary(value) do
    tokens = value |> String.split(" ", trim: true) |> Enum.map(&decode/1)

    if tokens == [] or :malformed in tokens,
      do: {:error, :malformed_header},
      else: {:ok, Enum.reject(tokens, &(&1 == :unknown))}
  end

  def parse_signature_header(_value), do: {:error, :malformed_header}

  defp decode("v1a," <> encoded), do: decode(:v1a, encoded, 64)
  defp decode("v1," <> encoded), do: decode(:v1, encoded, 32)

  defp decode(other) do
    if Regex.match?(@other_scheme, other), do: :unknown, else: :malformed
  end

  defp decode(scheme, encoded, size) do
    case Base.decode64(encoded) do
      {:ok, signature} when byte_size(signature) == size -> {scheme, signature}
      _other -> :malformed
    end
  end

  # WH-7 (2)
  # WH-49 (2)
  # WH-50
  # WH-51
  @doc """
  Verifies a message of the profile. `headers` are the request headers as they arrived (a list of pairs or a map; names are matched without regard to case), `raw_body` the bytes that arrived, `keys` every key that may have signed it, `now` the current time and `tolerance_s` the allowed distance between `now` and `webhook-timestamp` in seconds.

  The message is accepted when any signature verifies against any key. It is refused with `:missing_header`, `:duplicate_header` (a profile header that appears more than once), `:malformed_header`, `:timestamp_out_of_tolerance` or `:no_matching_signature`.
  """
  @spec verify(headers(), binary(), [key()], DateTime.t(), non_neg_integer()) ::
          {:ok, verified()} | {:error, rejection()}
  def verify(headers, raw_body, keys, %DateTime{} = now, tolerance_s)
      when is_binary(raw_body) and is_list(keys) and is_integer(tolerance_s) do
    with {:ok, id} <- header(headers, @id),
         {:ok, timestamp_text} <- header(headers, @timestamp),
         {:ok, signature_text} <- header(headers, @signature),
         {:ok, timestamp} <- timestamp(id, timestamp_text),
         {:ok, tokens} <- parse_signature_header(signature_text),
         :ok <- fresh(timestamp, DateTime.to_unix(now), tolerance_s) do
      match(tokens, keys, signed_content(id, timestamp, raw_body), id, timestamp)
    end
  end

  defp header(headers, name) do
    case values(headers, name) do
      [value] when is_binary(value) -> {:ok, value}
      [] -> {:error, :missing_header}
      [_value] -> {:error, :malformed_header}
      _several -> {:error, :duplicate_header}
    end
  end

  defp values(headers, name) when is_map(headers), do: headers |> Map.to_list() |> values(name)

  defp values(headers, name) when is_list(headers) do
    for {key, value} <- headers,
        is_binary(key),
        String.downcase(key, :ascii) == name,
        item <- List.wrap(value),
        do: item
  end

  defp values(_headers, _name), do: []

  defp timestamp(id, text) do
    if Regex.match?(@id_syntax, id) and Regex.match?(@timestamp_syntax, text),
      do: {:ok, String.to_integer(text)},
      else: {:error, :malformed_header}
  end

  # WH-7 (2)
  defp fresh(timestamp, now, tolerance_s) do
    if abs(now - timestamp) <= tolerance_s, do: :ok, else: {:error, :timestamp_out_of_tolerance}
  end

  defp match(tokens, keys, content, id, timestamp) do
    pairs = for token <- tokens, key <- keys, do: {token, key}

    case Enum.reduce(pairs, nil, &accept(&1, &2, content)) do
      nil -> {:error, :no_matching_signature}
      scheme -> {:ok, %{id: id, timestamp: timestamp, scheme: scheme}}
    end
  end

  defp accept({{scheme, signature}, key}, found, content) do
    if valid?(scheme, signature, key, content), do: found || scheme, else: found
  end

  defp valid?(:v1a, signature, {:ed25519, <<_::256>> = public_key}, content),
    do: :crypto.verify(:eddsa, :none, content, signature, [public_key, :ed25519])

  # TN-35
  defp valid?(:v1, signature, {:hmac, secret}, content),
    do: Crypto.secure_compare(Crypto.hmac_sha256(secret, content), signature)

  defp valid?(_scheme, _signature, _key, _content), do: false
end
