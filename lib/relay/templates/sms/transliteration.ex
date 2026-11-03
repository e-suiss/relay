defmodule Relay.Templates.Sms.Transliteration do
  @moduledoc """
  SMS transliteration (CH-49) and the optional typographic normalisation (CH-48).

  Transliteration replaces a letter the GSM 03.38 default alphabet cannot carry with its base letter (`ş` → `s`, `ğ` → `g`, `ı` → `i`, `İ` → `I`, `ç` → `c`, `â` → `a`); letters the alphabet carries (`Ç Ö ö Ü ü é`) stay. Normalisation replaces typographic characters that force UCS-2 (smart quotes, dashes, `…`, `₺`, NBSP and other spaces) with GSM equivalents. Both return `{text, changes}` (INV-1).

  Which text is transliterated depends on the message type (CH-49): the body of a `security` (OTP) message always, mandatory legal text never, any other body only when the template turns the flag on (default off).
  """

  alias Relay.Templates.Sanitizer
  alias Relay.Templates.Sms.Encoding

  @letters %{?ı => "i"}

  @typographic %{
    0x00A0 => " ",
    0x2000 => " ",
    0x2001 => " ",
    0x2002 => " ",
    0x2003 => " ",
    0x2004 => " ",
    0x2005 => " ",
    0x2006 => " ",
    0x2007 => " ",
    0x2008 => " ",
    0x2009 => " ",
    0x200A => " ",
    0x202F => " ",
    0x205F => " ",
    0x3000 => " ",
    0x2010 => "-",
    0x2011 => "-",
    0x2012 => "-",
    0x2013 => "-",
    0x2014 => "-",
    0x2015 => "-",
    0x2212 => "-",
    0x2018 => "'",
    0x2019 => "'",
    0x201A => "'",
    0x201B => "'",
    0x2032 => "'",
    0x0060 => "'",
    0x00B4 => "'",
    0x201C => "\"",
    0x201D => "\"",
    0x201E => "\"",
    0x201F => "\"",
    0x2033 => "\"",
    0x00AB => "\"",
    0x00BB => "\"",
    0x2026 => "...",
    0x20BA => "TL",
    0x2022 => "-",
    0x00B7 => "."
  }

  # CH-49
  @doc "True when the CH-49 rule transliterates a part (`:body` or `:legal`) of a message of `message_class`, given the template flag."
  @spec applies?(String.t(), :body | :legal, boolean()) :: boolean()
  def applies?(_message_class, :legal, _flag), do: false
  def applies?("security", :body, _flag), do: true
  def applies?(_message_class, :body, flag), do: flag == true

  # CH-49
  @doc "Replaces letters the GSM default alphabet cannot carry with their base letters."
  @spec transliterate(String.t()) :: Sanitizer.result()
  def transliterate(text) do
    {graphemes, count} =
      text
      |> String.graphemes()
      |> Enum.map_reduce(0, fn grapheme, count ->
        case base(grapheme) do
          nil -> {grapheme, count}
          replacement -> {replacement, count + 1}
        end
      end)

    result(Enum.join(graphemes), text, :transliterated, count)
  end

  # CH-48
  @doc "Replaces typographic characters that force UCS-2 with GSM equivalents."
  @spec normalize(String.t()) :: Sanitizer.result()
  def normalize(text) do
    {parts, count} =
      text
      |> String.to_charlist()
      |> Enum.map_reduce(0, fn codepoint, count ->
        case Map.fetch(@typographic, codepoint) do
          {:ok, replacement} -> {replacement, count + 1}
          :error -> {<<codepoint::utf8>>, count}
        end
      end)

    result(IO.iodata_to_binary(parts), text, :normalized, count)
  end

  # CH-48
  @doc "True when `normalize/1` has a GSM replacement for the code point."
  @spec normalizable?(non_neg_integer()) :: boolean()
  def normalizable?(codepoint), do: Map.has_key?(@typographic, codepoint)

  defp result(_new, text, _rule, 0), do: {text, []}
  defp result(new, _text, rule, count), do: {new, [Sanitizer.change(rule, :replaced, count)]}

  defp base(grapheme) do
    if Encoding.fits?(grapheme, :gsm7), do: nil, else: letter(grapheme)
  end

  defp letter(<<codepoint::utf8>>) when is_map_key(@letters, codepoint),
    do: Map.fetch!(@letters, codepoint)

  defp letter(grapheme) do
    stripped =
      for <<c::utf8 <- :unicode.characters_to_nfd_binary(grapheme)>>,
          c not in 0x0300..0x036F,
          into: "",
          do: <<c::utf8>>

    if stripped != "" and stripped != grapheme and Encoding.fits?(stripped, :gsm7),
      do: stripped,
      else: nil
  end
end
