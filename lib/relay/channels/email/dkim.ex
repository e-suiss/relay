defmodule Relay.Channels.Email.Dkim do
  @moduledoc """
  DKIM signatures (RFC 6376) of outgoing e-mail: `rsa-sha256` only (RFC 8301; `rsa-sha1` is never written), `relaxed/relaxed` canonicalization and RSA keys of at least 2048 bits (CH-36). The signature is computed by a signer function, never with a private key in application memory: `key_signer/1` signs inside the key store through `Relay.Keys.sign/3` (PKCS#1 v1.5 with SHA-256, TN-63).

  The signed header fields are those of a fixed list present in the message, each instance once, followed by one more `from`, `subject`, `list-unsubscribe`, `list-unsubscribe-post` and `feedback-id` each, so that adding one of those fields after signing breaks the signature. The fields Relay adds (`Relay.Channels.Email.Headers`) are always inside `h=` (CH-38).

  `verify/2` checks a signature with a public key; it reads `relaxed` and `simple` canonicalization so it can check the RFC examples, and it is used by tests and by the sending domain checks, never to accept mail.
  """

  alias Relay.Channels.Email.Mime
  alias Relay.Error

  @signed ~w(from sender reply-to subject date message-id to cc mime-version content-type
             content-transfer-encoding in-reply-to references list-id list-unsubscribe
             list-unsubscribe-post feedback-id)
  @oversigned ~w(from subject list-unsubscribe list-unsubscribe-post feedback-id)
  @min_bits 2048
  @fold 76
  @b_chunk 64

  @type signer :: (binary() -> {:ok, binary()} | {:error, Error.t()})
  @type params :: %{
          required(:domain) => String.t(),
          required(:selector) => String.t(),
          required(:timestamp) => non_neg_integer(),
          optional(:expires) => non_neg_integer() | nil,
          optional(:required) => [String.t()]
        }

  # CH-36
  # TN-63
  @doc "A signer for the RSA key `label` in the key store; a key shorter than 2048 bits is refused with `:dkim_key_too_short`."
  @spec key_signer(Relay.Keys.label()) :: {:ok, signer()} | {:error, Error.t()}
  def key_signer(label) when is_binary(label) and label != "" do
    with {:ok, {modulus, _exponent}} <- Relay.Keys.public_key(:rs256, label),
         :ok <- check_key(modulus) do
      {:ok, fn data -> Relay.Keys.sign(:rs256, label, data) end}
    end
  end

  # CH-36
  @doc "Checks that an RSA modulus (big-endian bytes or an integer) is at least 2048 bits."
  @spec check_key(binary() | pos_integer()) :: :ok | {:error, Error.t()}
  def check_key(modulus) do
    if key_bits(modulus) >= @min_bits,
      do: :ok,
      else: {:error, Error.new(:dkim_key_too_short, "a DKIM key has at least 2048 bits")}
  end

  @doc "The length in bits of an RSA modulus given as big-endian bytes or an integer."
  @spec key_bits(binary() | non_neg_integer()) :: non_neg_integer()
  def key_bits(modulus) when is_binary(modulus),
    do: modulus |> :binary.decode_unsigned() |> key_bits()

  def key_bits(0), do: 0

  def key_bits(modulus) when is_integer(modulus) and modulus > 0,
    do: modulus |> Integer.digits(2) |> length()

  # CH-36
  @doc "The DNS TXT record of a DKIM public key, `v=DKIM1; k=rsa; p=<SubjectPublicKeyInfo>`, split into strings of at most 255 bytes."
  @spec dns_record({binary() | pos_integer(), binary() | pos_integer()}) :: [String.t()]
  def dns_record({modulus, exponent}) do
    key = {:RSAPublicKey, integer(modulus), integer(exponent)}

    {:SubjectPublicKeyInfo, der, :not_encrypted} =
      :public_key.pem_entry_encode(:SubjectPublicKeyInfo, key)

    chunks("v=DKIM1; k=rsa; p=" <> Base.encode64(der), 255)
  end

  defp integer(value) when is_binary(value), do: :binary.decode_unsigned(value)
  defp integer(value) when is_integer(value), do: value

  # CH-36
  # CH-38
  @doc """
  Signs a message and returns its `DKIM-Signature` header field, without the final CRLF, to be placed before the other fields. `params` carries `:domain`, `:selector`, `:timestamp` (Unix seconds), an optional `:expires` and the `:required` field names that must be present and signed (the fields of `Relay.Channels.Email.Headers`). A message without `From`, or without a required field, is refused.
  """
  @spec sign(binary(), params(), signer()) :: {:ok, String.t()} | {:error, Error.t()}
  def sign(message, %{domain: domain, selector: selector, timestamp: timestamp} = params, signer)
      when is_binary(message) and is_function(signer, 1) do
    {head, body} = message |> Mime.crlf() |> Mime.split()
    fields = indexed(head)
    names = Enum.map(fields, &elem(&1, 0))
    required = params |> Map.get(:required, []) |> Enum.map(&String.downcase(&1, :ascii))

    with :ok <- present(names, ["from" | required]) do
      h = signed_names(names, required)

      tags =
        [
          {"v", "1"},
          {"a", "rsa-sha256"},
          {"c", "relaxed/relaxed"},
          {"d", domain},
          {"s", selector},
          {"t", Integer.to_string(timestamp)}
        ] ++
          expires(params) ++
          [{"h", Enum.join(h, ":")}, {"bh", body_hash(body, :relaxed)}]

      unsigned = fold(tags)
      data = signed_data(fields, h, unsigned, :relaxed)

      with {:ok, signature} <- signer.(data),
           do: {:ok, unsigned <> chunked_b(Base.encode64(signature))}
    end
  end

  defp expires(%{expires: expires}) when is_integer(expires),
    do: [{"x", Integer.to_string(expires)}]

  defp expires(_params), do: []

  defp present(names, required) do
    case Enum.reject(required, &(&1 in names)) do
      [] ->
        :ok

      missing ->
        {:error,
         Error.new(:dkim_header_missing, "a field to sign is missing", %{fields: missing})}
    end
  end

  defp signed_names(names, required) do
    listed =
      for name <- Enum.uniq(@signed ++ required),
          _instance <- Enum.filter(names, &(&1 == name)),
          do: name

    listed ++ @oversigned
  end

  defp fold(tags) do
    pieces = Enum.map(tags, fn {key, value} -> key <> "=" <> value <> ";" end)

    {lines, last} =
      Enum.reduce(pieces, {[], "DKIM-Signature:"}, fn piece, {lines, line} ->
        if byte_size(line) + 1 + byte_size(piece) > @fold and line != "DKIM-Signature:",
          do: {[line | lines], " " <> piece},
          else: {lines, line <> " " <> piece}
      end)

    [" b=", last | lines] |> Enum.reverse() |> Enum.join("\r\n")
  end

  defp chunked_b(b64), do: b64 |> chunks(@b_chunk) |> Enum.join("\r\n ")

  defp chunks(text, size) when byte_size(text) <= size, do: [text]

  defp chunks(text, size) do
    <<chunk::binary-size(^size), rest::binary>> = text
    [chunk | chunks(rest, size)]
  end

  @doc "The base64 SHA-256 hash of a body under `:relaxed` or `:simple` canonicalization."
  @spec body_hash(binary(), :relaxed | :simple) :: String.t()
  def body_hash(body, canonicalization),
    do: Base.encode64(:crypto.hash(:sha256, canonical_body(body, canonicalization)))

  # CH-36
  @doc "A body under `:relaxed` or `:simple` canonicalization (RFC 6376 §3.4.3, §3.4.4)."
  @spec canonical_body(binary(), :relaxed | :simple) :: binary()
  def canonical_body(body, canonicalization) do
    lines =
      body
      |> Mime.crlf()
      |> :binary.split("\r\n", [:global])
      |> Enum.map(&line(&1, canonicalization))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()

    case {lines, canonicalization} do
      {[], :relaxed} -> ""
      {[], :simple} -> "\r\n"
      {lines, _canonicalization} -> Enum.join(lines, "\r\n") <> "\r\n"
    end
  end

  defp line(line, :simple), do: line
  defp line(line, :relaxed), do: line |> collapse() |> String.trim_trailing(" ")

  # CH-36
  @doc "A header field as written, folding included, under `:relaxed` or `:simple` canonicalization, without the final CRLF (RFC 6376 §3.4.1, §3.4.2)."
  @spec canonical_header(binary(), :relaxed | :simple) :: binary()
  def canonical_header(field, :simple), do: field

  def canonical_header(field, :relaxed) do
    [name, value] =
      case :binary.split(field, ":") do
        [name, value] -> [name, value]
        [name] -> [name, ""]
      end

    value = value |> :binary.replace("\r\n", "", [:global]) |> collapse() |> String.trim(" ")
    (name |> collapse() |> String.trim(" ") |> String.downcase(:ascii)) <> ":" <> value
  end

  defp collapse(text), do: Regex.replace(~r/[ \t]+/, text, " ")

  defp indexed(head) do
    head
    |> Mime.raw_fields()
    |> Enum.map(fn raw ->
      [name | _rest] = :binary.split(raw, ":")
      {name |> String.trim() |> String.downcase(:ascii), raw}
    end)
  end

  defp signed_data(fields, h, signature_field, canonicalization) do
    {selected, _used} =
      Enum.map_reduce(h, %{}, fn name, used ->
        n = Map.get(used, name, 0)
        instances = for {^name, raw} <- Enum.reverse(fields), do: raw
        {Enum.at(instances, n), Map.put(used, name, n + 1)}
      end)

    headers =
      selected
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(&(canonical_header(&1, canonicalization) <> "\r\n"))

    headers <> canonical_header(signature_field, canonicalization)
  end

  # CH-36
  @doc """
  Verifies the `rsa-sha256` DKIM signatures of a message with an RSA public key, given as `{:RSAPublicKey, modulus, exponent}` or as the base64 `p=` value of a DKIM record. It is `:ok` when one signature verifies; the `l=` tag is not supported.
  """
  @spec verify(binary(), tuple() | String.t()) :: :ok | {:error, atom()}
  def verify(message, key) when is_binary(message) do
    case public_key(key) do
      {:ok, public_key} -> verify_all(message, public_key)
      :error -> {:error, :invalid_key}
    end
  end

  defp verify_all(message, public_key) do
    {head, body} = message |> Mime.crlf() |> Mime.split()
    fields = indexed(head)

    results =
      fields
      |> Enum.filter(&(elem(&1, 0) == "dkim-signature"))
      |> Enum.map(fn {_name, raw} -> {raw, tags(raw)} end)
      |> Enum.filter(fn {_raw, tags} -> tags["a"] == "rsa-sha256" end)
      |> Enum.map(fn {raw, tags} -> verify_one(raw, tags, fields, body, public_key) end)

    cond do
      :ok in results -> :ok
      results == [] -> {:error, :no_signature}
      true -> hd(results)
    end
  end

  defp verify_one(raw, tags, fields, body, public_key) do
    {header_c, body_c} = canonicalizations(tags["c"])

    with false <- Map.has_key?(tags, "l") or header_c == nil or body_c == nil,
         true <- strip(tags["bh"] || "") == body_hash(body, body_c),
         {:ok, signature} <- Base.decode64(strip(tags["b"] || "")) do
      h = (tags["h"] || "") |> String.split(":") |> Enum.map(&String.downcase(strip(&1), :ascii))
      unsigned = Regex.replace(~r/([;:][ \t\r\n]*b[ \t\r\n]*=)[^;]*/, raw, "\\1")
      data = signed_data(fields, h, unsigned, header_c)

      if :public_key.verify(data, :sha256, signature, public_key),
        do: :ok,
        else: {:error, :bad_signature}
    else
      true -> {:error, :unsupported}
      false -> {:error, :body_hash_mismatch}
      :error -> {:error, :bad_signature}
    end
  end

  defp canonicalizations(nil), do: {:simple, :simple}

  defp canonicalizations(value) do
    case value |> strip() |> String.split("/") do
      [header] -> {canonicalization(header), :simple}
      [header, body] -> {canonicalization(header), canonicalization(body)}
      _other -> {nil, nil}
    end
  end

  defp canonicalization("relaxed"), do: :relaxed
  defp canonicalization("simple"), do: :simple
  defp canonicalization(_other), do: nil

  @doc "The tags of a DKIM signature field or DKIM key record as a map; values are unfolded and trimmed."
  @spec tags(binary()) :: %{String.t() => String.t()}
  def tags(text) do
    value =
      case :binary.split(text, ":") do
        [name, value] -> if String.contains?(name, "="), do: text, else: value
        [only] -> only
      end

    value
    |> :binary.replace("\r\n", "", [:global])
    |> String.split(";")
    |> Enum.flat_map(fn tag ->
      case :binary.split(tag, "=") do
        [key, tag_value] -> [{String.trim(key), String.trim(tag_value)}]
        [_bare] -> []
      end
    end)
    |> Map.new()
  end

  defp strip(value), do: Regex.replace(~r/[ \t\r\n]+/, value, "")

  defp public_key({:RSAPublicKey, _modulus, _exponent} = key), do: {:ok, key}

  defp public_key(p) when is_binary(p) do
    with {:ok, der} <- Base.decode64(strip(p)) do
      decode_spki(der)
    end
  end

  @doc "Decodes the DER of a DKIM `p=` value, a SubjectPublicKeyInfo or a bare RSAPublicKey, into `{:RSAPublicKey, modulus, exponent}`."
  @spec decode_spki(binary()) :: {:ok, tuple()} | :error
  def decode_spki(der) when is_binary(der) do
    entry = {:SubjectPublicKeyInfo, der, :not_encrypted}

    case safe(fn -> :public_key.pem_entry_decode(entry) end) do
      {:ok, {:RSAPublicKey, _modulus, _exponent}} = key -> key
      _other -> rsa_public_key(safe(fn -> :public_key.der_decode(:RSAPublicKey, der) end))
    end
  end

  defp rsa_public_key({:ok, {:RSAPublicKey, _modulus, _exponent}} = key), do: key
  defp rsa_public_key(_other), do: :error

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end
end
