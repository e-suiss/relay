defmodule EsuissRelay.Webhook do
  @moduledoc """
  Verifies the webhooks Relay (and Access) send, over the raw request body.

      {:ok, %{id: id}} =
        EsuissRelay.Webhook.verify(conn.req_headers, raw_body, ["whpk_..."])

  Pass the body exactly as the bytes arrived, never a body that was parsed and encoded again.
  A message is accepted when any of its signatures verifies against any of the keys:
  `whpk_<base64>` is an Ed25519 public key (`v1a` signatures, the default), `whsec_<base64>` an
  HMAC-SHA256 secret (`v1` signatures). HMAC signatures are compared in constant time and a
  `webhook-timestamp` more than the tolerance (default 300 seconds) away from now, in either
  direction, is refused. Deduplicate by the returned `id`: delivery is at least once.

  Rejections: `:missing_header`, `:duplicate_header`, `:malformed_header`,
  `:timestamp_out_of_tolerance`, `:no_matching_signature`, and `:invalid_key` for a key that is
  not in one of the two forms.
  """

  @id_syntax ~r/\A[\x21-\x7E]{1,256}\z/
  @timestamp_syntax ~r/\A(?:0|[1-9][0-9]{0,14})\z/
  @other_scheme ~r/\Av[0-9][0-9a-z]{0,7},[A-Za-z0-9+\/=_-]+\z/

  @type scheme :: :v1a | :v1
  @type key :: {:ed25519, <<_::256>>} | {:hmac, binary()}
  @type rejection ::
          :missing_header
          | :duplicate_header
          | :malformed_header
          | :timestamp_out_of_tolerance
          | :no_matching_signature
          | :invalid_key
  @type verified :: %{id: String.t(), timestamp: non_neg_integer(), scheme: scheme()}

  @doc "Parses the text form of a key: `whpk_<base64>` or `whsec_<base64>` (at least 24 bytes)."
  @spec parse_key(term()) :: {:ok, key()} | :error
  def parse_key("whpk_" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::256>> = public_key} -> {:ok, {:ed25519, public_key}}
      _other -> :error
    end
  end

  def parse_key("whsec_" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, secret} when byte_size(secret) >= 24 -> {:ok, {:hmac, secret}}
      _other -> :error
    end
  end

  def parse_key({:ed25519, <<_::256>>} = key), do: {:ok, key}
  def parse_key({:hmac, secret} = key) when is_binary(secret), do: {:ok, key}
  def parse_key(_other), do: :error

  @doc "The signed content of a message: `<id>.<timestamp>.<raw body>`."
  @spec signed_content(String.t(), non_neg_integer(), binary()) :: binary()
  def signed_content(id, timestamp, raw_body),
    do: <<id::binary, ?., Integer.to_string(timestamp)::binary, ?., raw_body::binary>>

  # WH-4
  # WH-7
  # API-65
  @doc """
  Verifies a message. `headers` are the request headers (a list of pairs or a map; names match
  without regard to case), `raw_body` the bytes that arrived and `keys` every key that may have
  signed it. Options: `:tolerance` in seconds (default 300) and `:now` in Unix seconds.
  """
  @spec verify(list() | map(), binary(), [String.t() | key()], keyword()) ::
          {:ok, verified()} | {:error, rejection()}
  def verify(headers, raw_body, keys, opts \\ []) when is_binary(raw_body) and is_list(keys) do
    tolerance = Keyword.get(opts, :tolerance, 300)
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, keys} <- parse_keys(keys),
         {:ok, id} <- header(headers, "webhook-id"),
         {:ok, timestamp_text} <- header(headers, "webhook-timestamp"),
         {:ok, signature_text} <- header(headers, "webhook-signature"),
         {:ok, timestamp} <- timestamp(id, timestamp_text),
         {:ok, tokens} <- parse_signature_header(signature_text),
         :ok <- fresh(timestamp, now, tolerance) do
      match(tokens, keys, signed_content(id, timestamp, raw_body), id, timestamp)
    end
  end

  defp parse_keys(keys) do
    parsed = Enum.map(keys, &parse_key/1)

    if :error in parsed,
      do: {:error, :invalid_key},
      else: {:ok, Enum.map(parsed, fn {:ok, key} -> key end)}
  end

  @doc "Parses a `webhook-signature` value into its `{scheme, signature}` tokens."
  @spec parse_signature_header(term()) :: {:ok, [{scheme(), binary()}]} | {:error, :malformed_header}
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

  defp timestamp(id, text) do
    if Regex.match?(@id_syntax, id) and Regex.match?(@timestamp_syntax, text),
      do: {:ok, String.to_integer(text)},
      else: {:error, :malformed_header}
  end

  defp fresh(timestamp, now, tolerance) do
    if abs(now - timestamp) <= tolerance, do: :ok, else: {:error, :timestamp_out_of_tolerance}
  end

  defp match(tokens, keys, content, id, timestamp) do
    found =
      Enum.find_value(tokens, fn {scheme, signature} ->
        if Enum.any?(keys, &valid?(scheme, signature, &1, content)), do: scheme
      end)

    case found do
      nil -> {:error, :no_matching_signature}
      scheme -> {:ok, %{id: id, timestamp: timestamp, scheme: scheme}}
    end
  end

  defp valid?(:v1a, signature, {:ed25519, public_key}, content),
    do: :crypto.verify(:eddsa, :none, content, signature, [public_key, :ed25519])

  defp valid?(:v1, signature, {:hmac, secret}, content),
    do: :crypto.hash_equals(:crypto.mac(:hmac, :sha256, secret, content), signature)

  defp valid?(_scheme, _signature, _key, _content), do: false
end
