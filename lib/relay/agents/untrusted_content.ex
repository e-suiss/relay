defmodule Relay.Agents.UntrustedContent do
  @moduledoc """
  The mark and the normalisation of untrusted text (AG-40, AG-68, TP-44). Free text of a person or of an external system reaches an agent only as data: between two boundary marks that carry a random value of the part, and reduced to the text a person would see. The module is pure; the vectors under `conformance/vectors/untrusted-content` fix every rule.

  The mark: the text starts with `<<<relay:untrusted:N>>>` and ends with `<<<relay:end:N>>>`, where `N` is 32 lowercase hexadecimal digits of 128 random bits drawn for the part (`nonce/0`) and carried in a typed field of the part as well. Every `<<<relay:` inside the text is written `<<<relay%3A`, so the text can neither close its own mark nor open another.

  The normalisation, in this order:

    1. For HTML, comments, declarations and processing instructions are dropped; an element named `script`, `style`, `template`, `head` or `noscript`, one with the attribute `hidden` or `aria-hidden="true"`, and one whose inline style declares `display:none`, `visibility:hidden`, `opacity:0` or `font-size:0` is dropped with its content; every other tag is dropped and its text kept. An inline style that cannot be read without interpreting a CSS escape hides its element. Numeric character references and `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;` and `&nbsp;` are replaced by their character in the text that is kept. An element that is never closed hides the rest of the text.
    2. Unicode normalisation form C.
    3. Invisible characters are dropped: control characters other than tab, line feed and carriage return, zero-width characters, bidirectional controls, tag characters, variation selectors and the other code points of AG-68 (2c).

  Bytes that are not UTF-8 become U+FFFD before anything else.
  """

  @guard "<<<relay:"
  @escaped "<<<relay%3A"
  @dropped_elements ~w(script style template head noscript)
  @raw_elements ~w(script style)
  @void_elements ~w(area base br col embed hr img input link meta param source track wbr)
  @zero ~r/\A[+-]?(?:0+(?:\.0*)?|\.0+)(?:[a-z]*|%)\z/
  @replacement <<0xFFFD::utf8>>
  @nbsp <<0xA0::utf8>>
  @reference ~r/&(#[0-9]+|#[xX][0-9a-fA-F]+|amp|lt|gt|quot|apos|nbsp);/

  @type format :: :plain | :html
  @type nonce :: <<_::256>>

  # AG-68 (1)
  @doc "A fresh value of a part's mark: 128 random bits as 32 lowercase hexadecimal digits."
  @spec nonce() :: nonce()
  def nonce, do: Base.encode16(Relay.Random.bytes(16), case: :lower)

  # AG-68 (1)
  @doc "Whether a value is a mark value: 32 lowercase hexadecimal digits."
  @spec nonce?(term()) :: boolean()
  def nonce?(<<_::256>> = value), do: Regex.match?(~r/\A[0-9a-f]{32}\z/, value)
  def nonce?(_other), do: false

  # AG-68 (1)
  # AG-40
  @doc "Writes every `<<<relay:` of a text as `<<<relay%3A`."
  @spec escape(String.t()) :: String.t()
  def escape(text) when is_binary(text), do: String.replace(text, @guard, @escaped)

  # AG-68 (1)
  # AG-40
  @doc "The text between its boundary marks, with every mark inside it escaped."
  @spec mark(String.t(), nonce()) :: String.t()
  def mark(text, <<_::256>> = nonce) when is_binary(text),
    do: opening(nonce) <> escape(text) <> closing(nonce)

  # AG-68 (1)
  @doc "The mark that opens the untrusted text of a part."
  @spec opening(nonce()) :: String.t()
  def opening(<<_::256>> = nonce), do: "<<<relay:untrusted:" <> nonce <> ">>>"

  # AG-68 (1)
  @doc "The mark that closes the untrusted text of a part."
  @spec closing(nonce()) :: String.t()
  def closing(<<_::256>> = nonce), do: "<<<relay:end:" <> nonce <> ">>>"

  # AG-68 (2)
  # AG-40
  # TP-44
  @doc "Reduces a text to what a person would see: HTML stripping for `:html`, then normalisation form C, then the removal of invisible characters."
  @spec normalise(binary(), format()) :: String.t()
  def normalise(text, format) when is_binary(text) and format in [:plain, :html] do
    text
    |> scrub()
    |> visible(format)
    |> String.normalize(:nfc)
    |> drop_invisible()
  end

  defp visible(text, :plain), do: text
  defp visible(text, :html), do: text |> walk([], nil) |> IO.iodata_to_binary()

  defp scrub(text) do
    if String.valid?(text), do: text, else: scrub(text, [])
  end

  defp scrub(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp scrub(<<char::utf8, rest::binary>>, acc), do: scrub(rest, [<<char::utf8>> | acc])
  defp scrub(<<_byte, rest::binary>>, acc), do: scrub(rest, [@replacement | acc])

  # AG-68 (2)
  defp walk(html, acc, hidden) do
    case :binary.split(html, "<") do
      [text] -> keep(acc, text, hidden)
      [text, rest] -> markup(rest, keep(acc, text, hidden), hidden)
    end
  end

  defp keep(acc, "", _hidden), do: acc
  defp keep(acc, text, nil), do: [acc, references(text)]
  defp keep(acc, _text, _hidden), do: acc

  defp markup("!--" <> rest, acc, hidden), do: after_mark(rest, "-->", acc, hidden)

  defp markup(<<char, _rest::binary>> = rest, acc, hidden) when char in [?!, ??],
    do: after_mark(rest, ">", acc, hidden)

  defp markup("/" <> rest, acc, hidden) do
    case name(rest, []) do
      {"", _rest} ->
        after_mark(rest, ">", acc, hidden)

      {name, rest} ->
        {_attributes, rest} = attributes(rest, %{})
        walk(rest, acc, closed(hidden, name))
    end
  end

  defp markup(<<char, _rest::binary>> = rest, acc, hidden)
       when char in ?a..?z or char in ?A..?Z do
    {name, rest} = name(rest, [])
    {attributes, rest} = attributes(rest, %{})
    opened(name, attributes, rest, acc, hidden)
  end

  defp markup(rest, acc, hidden), do: walk(rest, keep(acc, "<", hidden), hidden)

  defp after_mark(rest, mark, acc, hidden) do
    case :binary.split(rest, mark) do
      [_dropped, rest] -> walk(rest, acc, hidden)
      [_unterminated] -> acc
    end
  end

  defp opened(name, _attributes, rest, acc, hidden) when name in @raw_elements,
    do: walk(after_raw(rest, name), acc, hidden)

  defp opened(name, attributes, rest, acc, nil) do
    cond do
      not hidden?(name, attributes) -> walk(rest, acc, nil)
      name in @void_elements -> walk(rest, acc, nil)
      true -> walk(rest, acc, {name, 1})
    end
  end

  defp opened(name, _attributes, rest, acc, {name, depth}) when name not in @void_elements,
    do: walk(rest, acc, {name, depth + 1})

  defp opened(_name, _attributes, rest, acc, hidden), do: walk(rest, acc, hidden)

  defp closed({name, 1}, name), do: nil
  defp closed({name, depth}, name), do: {name, depth - 1}
  defp closed(hidden, _name), do: hidden

  defp after_raw(rest, name) do
    case :binary.match(ascii_downcase(rest), "</" <> name) do
      {at, length} ->
        tail = binary_part(rest, at + length, byte_size(rest) - at - length)
        {_attributes, tail} = attributes(tail, %{})
        tail

      :nomatch ->
        ""
    end
  end

  defp ascii_downcase(text),
    do: for(<<byte <- text>>, into: "", do: <<downcase(byte)>>)

  defp downcase(byte) when byte in ?A..?Z, do: byte + 32
  defp downcase(byte), do: byte

  defp name(<<char, rest::binary>>, acc)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?-, ?:, ?_],
       do: name(rest, [downcase(char) | acc])

  defp name(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}

  defp attributes(<<>>, attributes), do: {attributes, ""}
  defp attributes(">" <> rest, attributes), do: {attributes, rest}

  defp attributes(<<char, rest::binary>>, attributes) when char in [?\s, ?\t, ?\n, ?\r, ?\f, ?/],
    do: attributes(rest, attributes)

  defp attributes(rest, attributes) do
    {name, rest} = attribute_name(rest, [])
    {value, rest} = attribute_value(skip_space(rest))
    attributes(rest, Map.put_new(attributes, name, value))
  end

  defp attribute_name(<<?=, rest::binary>>, []), do: attribute_name(rest, [?=])

  defp attribute_name(<<char, _rest::binary>> = rest, acc)
       when char in [?\s, ?\t, ?\n, ?\r, ?\f, ?/, ?>, ?=],
       do: {named(acc), rest}

  defp attribute_name(<<char, rest::binary>>, acc),
    do: attribute_name(rest, [downcase(char) | acc])

  defp attribute_name(<<>>, acc), do: {named(acc), ""}

  defp named(acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  defp skip_space(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r, ?\f],
    do: skip_space(rest)

  defp skip_space(rest), do: rest

  defp attribute_value("=" <> rest) do
    case skip_space(rest) do
      <<quote, quoted::binary>> when quote in [?", ?'] -> quoted_value(quoted, <<quote>>)
      unquoted -> unquoted_value(unquoted, [])
    end
  end

  defp attribute_value(rest), do: {"", rest}

  defp quoted_value(quoted, quote) do
    case :binary.split(quoted, quote) do
      [value, rest] -> {value, rest}
      [value] -> {value, ""}
    end
  end

  defp unquoted_value(<<char, _rest::binary>> = rest, acc)
       when char in [?\s, ?\t, ?\n, ?\r, ?\f, ?>],
       do: {named(acc), rest}

  defp unquoted_value(<<char, rest::binary>>, acc), do: unquoted_value(rest, [char | acc])
  defp unquoted_value(<<>>, acc), do: {named(acc), ""}

  defp hidden?(name, attributes) do
    name in @dropped_elements or is_map_key(attributes, "hidden") or
      aria_hidden?(attributes) or hidden_style?(attributes)
  end

  defp aria_hidden?(%{"aria-hidden" => value}),
    do: value |> references() |> String.trim() |> ascii_downcase() == "true"

  defp aria_hidden?(_attributes), do: false

  defp hidden_style?(%{"style" => value}) do
    style = value |> references() |> ascii_downcase()

    String.contains?(style, "\\") or
      style
      |> String.replace(~r{/\*.*?(\*/|\z)}s, "")
      |> String.replace(~r/\s+/u, "")
      |> String.split(";", trim: true)
      |> Enum.any?(&hiding?/1)
  end

  defp hidden_style?(_attributes), do: false

  defp hiding?(declaration) do
    case String.split(String.replace(declaration, "!important", ""), ":", parts: 2) do
      ["display", "none"] -> true
      ["visibility", "hidden"] -> true
      ["opacity", value] -> Regex.match?(@zero, value)
      ["font-size", value] -> Regex.match?(@zero, value)
      _other -> false
    end
  end

  defp references(text) do
    if String.contains?(text, "&"),
      do: Regex.replace(@reference, text, fn _all, reference -> character(reference) end),
      else: text
  end

  defp character("amp"), do: "&"
  defp character("lt"), do: "<"
  defp character("gt"), do: ">"
  defp character("quot"), do: "\""
  defp character("apos"), do: "'"
  defp character("nbsp"), do: @nbsp
  defp character("#x" <> digits), do: code_point(digits, 16)
  defp character("#X" <> digits), do: code_point(digits, 16)
  defp character("#" <> digits), do: code_point(digits, 10)

  defp code_point(digits, base) do
    case String.trim_leading(digits, "0") do
      significant when byte_size(significant) in 1..7 ->
        significant |> String.to_integer(base) |> code_point()

      _zero_or_too_long ->
        @replacement
    end
  end

  defp code_point(code) when code in 0x1..0xD7FF or code in 0xE000..0x10FFFF,
    do: <<code::utf8>>

  defp code_point(_invalid), do: @replacement

  # AG-68 (2)
  defp drop_invisible(text),
    do: for(<<char::utf8 <- text>>, not invisible?(char), into: "", do: <<char::utf8>>)

  defp invisible?(char) when char in [?\t, ?\n, ?\r], do: false
  defp invisible?(char) when char <= 0x1F, do: true
  defp invisible?(char) when char in 0x7F..0x9F, do: true
  defp invisible?(char) when char in 0x200B..0x200F, do: true
  defp invisible?(char) when char in 0x2060..0x2064, do: true
  defp invisible?(0xFEFF), do: true
  defp invisible?(char) when char in 0x202A..0x202E, do: true
  defp invisible?(char) when char in 0x2066..0x2069, do: true
  defp invisible?(char) when char in 0xE0000..0xE007F, do: true
  defp invisible?(char) when char in 0xFE00..0xFE0F, do: true
  defp invisible?(char) when char in 0xE0100..0xE01EF, do: true
  defp invisible?(char) when char in [0x00AD, 0x034F, 0x061C, 0x115F, 0x1160], do: true
  defp invisible?(char) when char in [0x17B4, 0x17B5, 0x3164, 0xFFA0], do: true
  defp invisible?(char) when char in 0x180B..0x180F, do: true
  defp invisible?(char) when char in 0xFFF9..0xFFFB, do: true
  defp invisible?(_char), do: false
end
