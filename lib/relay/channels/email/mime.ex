defmodule Relay.Channels.Email.Mime do
  @moduledoc """
  A small reader for the mail Relay receives (RFC 5322, RFC 2045, RFC 2046): a message is split into its unfolded header fields and its body, `Content-Type` parameters are read, multipart bodies are split on their boundary, and `base64` and `quoted-printable` bodies are decoded. Line endings are normalized to CRLF first. It only reads; Relay builds outgoing mail elsewhere.
  """

  @type header :: {String.t(), String.t()}
  @type part :: %{headers: [header()], body: binary()}

  @doc "Normalizes every line ending of `text` to CRLF."
  @spec crlf(binary()) :: binary()
  def crlf(text) when is_binary(text) do
    text
    |> :binary.replace("\r\n", "\n", [:global])
    |> :binary.replace("\r", "\n", [:global])
    |> :binary.replace("\n", "\r\n", [:global])
  end

  @doc "Splits a message into its header fields, unfolded with names lowercased, and its body."
  @spec parse(binary()) :: part()
  def parse(message) when is_binary(message) do
    {head, body} = split(crlf(message))
    %{headers: fields(head), body: body}
  end

  @doc "Splits a CRLF message into its raw header block, without the blank line, and its body."
  @spec split(binary()) :: {binary(), binary()}
  def split("\r\n" <> body), do: {"", body}

  def split(message) do
    case :binary.split(message, "\r\n\r\n") do
      [head, body] -> {head, body}
      [head] -> {head, ""}
    end
  end

  @doc "Reads a raw header block into unfolded `{name, value}` fields, names lowercased and values trimmed."
  @spec fields(binary()) :: [header()]
  def fields(head) when is_binary(head) do
    head
    |> raw_fields()
    |> Enum.flat_map(fn raw ->
      case :binary.split(raw, ":") do
        [name, value] ->
          unfolded = :binary.replace(value, "\r\n", "", [:global])
          [{name |> String.trim() |> String.downcase(:ascii), String.trim(unfolded)}]

        [_no_colon] ->
          []
      end
    end)
  end

  @doc "Splits a raw header block into its fields as written, each with its folding kept."
  @spec raw_fields(binary()) :: [binary()]
  def raw_fields(""), do: []

  def raw_fields(head) when is_binary(head) do
    head
    |> :binary.split("\r\n", [:global])
    |> Enum.reduce([], fn
      <<c, _rest::binary>> = line, [previous | done] when c in [?\s, ?\t] ->
        [previous <> "\r\n" <> line | done]

      "", done ->
        done

      line, done ->
        [line | done]
    end)
    |> Enum.reverse()
  end

  @doc "The value of the first header field named `name` (lowercase), or `nil`."
  @spec header([header()], String.t()) :: String.t() | nil
  def header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  @doc "The values of every header field named `name` (lowercase), in order."
  @spec headers([header()], String.t()) :: [String.t()]
  def headers(headers, name) do
    for {^name, value} <- headers, do: value
  end

  @doc "The media type, lowercased, and the parameters of a part; a part without `Content-Type` is `text/plain`."
  @spec content_type([header()]) :: {String.t(), %{String.t() => String.t()}}
  def content_type(headers) do
    case header(headers, "content-type") do
      nil -> {"text/plain", %{}}
      value -> parse_content_type(value)
    end
  end

  @doc "Parses a `Content-Type` value into its media type, lowercased, and its parameters."
  @spec parse_content_type(String.t()) :: {String.t(), %{String.t() => String.t()}}
  def parse_content_type(value) do
    [type | params] = split_params(value, "", false, [])
    params = params |> Enum.flat_map(&param/1) |> Map.new()
    {type |> String.trim() |> String.downcase(:ascii), params}
  end

  defp split_params(<<>>, acc, _quoted, parts), do: Enum.reverse([acc | parts])

  defp split_params(<<?\\, c, rest::binary>>, acc, true, parts),
    do: split_params(rest, <<acc::binary, ?\\, c>>, true, parts)

  defp split_params(<<?", rest::binary>>, acc, quoted, parts),
    do: split_params(rest, <<acc::binary, ?">>, not quoted, parts)

  defp split_params(<<?;, rest::binary>>, acc, false, parts),
    do: split_params(rest, "", false, [acc | parts])

  defp split_params(<<c, rest::binary>>, acc, quoted, parts),
    do: split_params(rest, <<acc::binary, c>>, quoted, parts)

  defp param(text) do
    case :binary.split(text, "=") do
      [key, value] -> [{key |> String.trim() |> String.downcase(:ascii), unquote_value(value)}]
      [_bare] -> []
    end
  end

  defp unquote_value(value) do
    case String.trim(value) do
      <<?", rest::binary>> = quoted when byte_size(rest) > 0 ->
        if String.ends_with?(quoted, "\""),
          do: rest |> binary_part(0, byte_size(rest) - 1) |> unescape(""),
          else: quoted

      plain ->
        plain
    end
  end

  defp unescape(<<>>, acc), do: acc
  defp unescape(<<?\\, c, rest::binary>>, acc), do: unescape(rest, <<acc::binary, c>>)
  defp unescape(<<c, rest::binary>>, acc), do: unescape(rest, <<acc::binary, c>>)

  @doc "The parts of a multipart body delimited by `boundary`; the preamble and the epilogue are dropped."
  @spec parts(binary(), String.t()) :: [part()]
  def parts(body, boundary) when is_binary(body) and is_binary(boundary) and boundary != "" do
    ("\r\n" <> body)
    |> :binary.split("\r\n--" <> boundary, [:global])
    |> tl()
    |> Enum.take_while(&(not String.starts_with?(&1, "--")))
    |> Enum.map(fn piece ->
      case :binary.split(piece, "\r\n") do
        [_padding, content] -> parse(content)
        [_padding] -> %{headers: [], body: ""}
      end
    end)
  end

  @doc "The body of a part with its `Content-Transfer-Encoding` removed; a body that does not decode is returned as it is."
  @spec decoded(part()) :: binary()
  def decoded(%{headers: headers, body: body}) do
    case headers |> header("content-transfer-encoding") |> encoding() do
      "base64" -> base64(body)
      "quoted-printable" -> quoted_printable(body, "")
      _identity -> body
    end
  end

  defp encoding(nil), do: nil
  defp encoding(value), do: value |> String.trim() |> String.downcase(:ascii)

  defp base64(body) do
    compact = for <<c <- body>>, c not in [?\r, ?\n, ?\s, ?\t, ?=], into: "", do: <<c>>

    case Base.decode64(compact, padding: false) do
      {:ok, decoded} -> decoded
      :error -> body
    end
  end

  defp quoted_printable(<<>>, acc), do: acc

  defp quoted_printable(<<"=\r\n", rest::binary>>, acc), do: quoted_printable(rest, acc)

  defp quoted_printable(<<?=, a, b, rest::binary>> = all, acc) do
    case Base.decode16(<<a, b>>, case: :mixed) do
      {:ok, byte} -> quoted_printable(rest, acc <> byte)
      :error -> quoted_printable(binary_part(all, 1, byte_size(all) - 1), <<acc::binary, ?=>>)
    end
  end

  defp quoted_printable(<<c, rest::binary>>, acc), do: quoted_printable(rest, <<acc::binary, c>>)

  @doc "Every leaf part of a message tree, depth first, with its media type; a `message/*` part is a leaf."
  @spec leaves(part()) :: [{String.t(), part()}]
  def leaves(%{headers: headers} = part) do
    case content_type(headers) do
      {"multipart/" <> _subtype, %{"boundary" => boundary}} ->
        part.body |> parts(boundary) |> Enum.flat_map(&leaves/1)

      {type, _params} ->
        [{type, part}]
    end
  end
end
