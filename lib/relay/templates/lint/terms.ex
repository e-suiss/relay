defmodule Relay.Templates.Lint.Terms do
  @moduledoc """
  Term matching shared by the dictionary lints (TP-46, TP-54). A term entry is a map with string keys: `"term"` (the stem or phrase), `"locale"` (a BCP 47 tag or `nil` for every locale) and `"category"` (a free label such as `"health"`, or `nil`); the caller passes active entries only.

  Text and terms are folded the same way: locale-aware lowercasing (Turkish and Azerbaijani dotted and dotless i), accent folding (decomposition without combining marks, `ı` → `i`) and whitespace collapsing. A term matches where it starts at a word start, so a stem matches its suffixed forms (`borc` matches "Borcunuz"). An entry is used when its locale is `nil` or has the primary language of the text's locale.
  """

  @type entry :: %{required(String.t()) => String.t() | nil}
  @type match :: %{term: String.t(), category: String.t() | nil, locale: String.t() | nil}

  @turkic ["tr", "az"]

  # TP-46
  @doc "Folds text for matching: locale-aware lowercase, accents removed, whitespace collapsed."
  @spec fold(String.t(), String.t() | nil) :: String.t()
  def fold(text, locale) do
    mode = if language(locale) in @turkic, do: :turkic, else: :default
    decomposed = text |> String.downcase(mode) |> :unicode.characters_to_nfd_binary()
    folded = for <<c::utf8 <- decomposed>>, c not in 0x0300..0x036F, into: "", do: <<c::utf8>>

    folded
    |> String.replace("ı", "i")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # TP-46
  @doc "Turns a variable path into words: `user.debtAmount` and `user.debt_amount` both read `user debt amount`."
  @spec words(String.t()) :: String.t()
  def words(name) do
    name
    |> String.replace(~r/([\p{Ll}\p{N}])(\p{Lu})/u, "\\1 \\2")
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
  end

  # TP-46
  # TP-54
  @doc "The entries that match any of the texts, in entry order, each once."
  @spec scan([String.t()], [entry()], String.t() | nil) :: [match()]
  def scan(texts, entries, locale) do
    folded = Enum.map(texts, &fold(&1, locale))

    entries
    |> Enum.filter(&(applies?(&1, locale) and found?(&1, folded, locale)))
    |> Enum.map(&%{term: &1["term"], category: &1["category"], locale: &1["locale"]})
    |> Enum.uniq()
  end

  defp found?(entry, folded, locale) do
    case fold(Map.get(entry, "term") || "", locale) do
      "" -> false
      term -> Enum.any?(folded, &word_start?(&1, term))
    end
  end

  # TP-46
  @doc "True when `term` occurs in `text` at a word start; both are already folded."
  @spec word_start?(String.t(), String.t()) :: boolean()
  def word_start?(text, term) do
    text
    |> :binary.matches(term)
    |> Enum.any?(fn {position, _length} -> boundary?(text, position) end)
  end

  defp boundary?(_text, 0), do: true

  defp boundary?(text, position) do
    start = max(position - 4, 0)
    tail = binary_part(text, start, position - start)

    case Enum.find_value(0..(byte_size(tail) - 1), &last_codepoint(tail, &1)) do
      nil -> true
      codepoint -> not Regex.match?(~r/\A[\p{L}\p{N}]\z/u, <<codepoint::utf8>>)
    end
  end

  defp last_codepoint(tail, skip) do
    case binary_part(tail, skip, byte_size(tail) - skip) do
      <<codepoint::utf8>> -> codepoint
      _other -> nil
    end
  end

  defp applies?(entry, locale) do
    case Map.get(entry, "locale") do
      nil -> true
      term_locale -> language(term_locale) == language(locale)
    end
  end

  defp language(nil), do: nil
  defp language(locale), do: locale |> String.downcase() |> String.split(["-", "_"]) |> hd()
end
