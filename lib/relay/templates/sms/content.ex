defmodule Relay.Templates.Sms.Content do
  @moduledoc """
  SMS content rules (TP-19). Control characters other than line feed and carriage return, zero-width characters and direction controls (U+202A–U+202E, the isolates U+2066–U+2069, U+200E, U+200F and U+061C) are removed from SMS text. Emoji are forbidden in template text, which is a publish error, and flagged in variable values, where the tenant policy either strips them or accepts the cost; neither passes silently (INV-1).
  """

  alias Relay.Templates.Finding
  alias Relay.Templates.Sanitizer

  @type emoji_policy :: :strip | :accept

  @zero_width [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x180E]
  @direction [
    0x061C,
    0x200E,
    0x200F,
    0x202A,
    0x202B,
    0x202C,
    0x202D,
    0x202E,
    0x2066,
    0x2067,
    0x2068,
    0x2069
  ]
  @emoji_ranges [
    0x1F000..0x1FAFF,
    0x2300..0x23FF,
    0x2600..0x27BF,
    0x2B00..0x2BFF,
    0xE0020..0xE007F
  ]
  @emoji_singles [0xFE0F, 0x203C, 0x2049, 0x3030, 0x303D, 0x3297, 0x3299]

  # TP-19
  @doc "Removes invalid UTF-8, control, zero-width and direction control characters."
  @spec sanitize(binary(), String.t() | nil) :: Sanitizer.result()
  def sanitize(text, field \\ nil) do
    Sanitizer.pipe(text, [
      &Sanitizer.utf8(&1, field),
      &Sanitizer.drop(&1, :control_character, field, fn c -> control?(c) end),
      &Sanitizer.drop(&1, :zero_width, field, fn c -> c in @zero_width end),
      &Sanitizer.drop(&1, :direction_control, field, fn c -> c in @direction end)
    ])
  end

  # TP-19
  @doc "True when the code point is an emoji or an emoji component (presentation selector, tag)."
  @spec emoji_codepoint?(non_neg_integer()) :: boolean()
  def emoji_codepoint?(c), do: c in @emoji_singles or Enum.any?(@emoji_ranges, &(c in &1))

  # TP-19
  @doc "The graphemes of `text` that are or contain an emoji, in order."
  @spec emoji(String.t()) :: [String.t()]
  def emoji(text), do: text |> String.graphemes() |> Enum.filter(&emoji_grapheme?/1)

  # TP-19
  @doc "Publish gate check of static SMS template text: any emoji is a hard finding."
  @spec template_findings(String.t(), keyword()) :: [Finding.t()]
  def template_findings(static_text, opts \\ []) do
    case emoji(static_text) do
      [] ->
        []

      found ->
        [
          Finding.new(:sms_emoji, :hard,
            channel: :sms,
            locale: Keyword.get(opts, :locale),
            pointer: Keyword.get(opts, :pointer, "/body"),
            detail: %{count: length(found), codepoints: codepoints(found)}
          )
        ]
    end
  end

  # TP-19
  @doc "Cleans one variable value before it is injected into SMS text: sanitises it, then strips emoji or records that they were accepted."
  @spec clean_value(binary(), emoji_policy(), String.t() | nil) :: Sanitizer.result()
  def clean_value(value, policy, field \\ nil) when policy in [:strip, :accept] do
    {clean, changes} = sanitize(value, field)
    {final, more} = emoji_rule(clean, policy, field)
    {final, changes ++ more}
  end

  defp emoji_rule(text, policy, field) do
    case emoji(text) do
      [] ->
        {text, []}

      found ->
        detail = %{codepoints: codepoints(found)}
        action = if policy == :strip, do: :removed, else: :flagged
        change = Sanitizer.change(:emoji, action, length(found), field: field, detail: detail)
        {apply_emoji_policy(text, policy), [change]}
    end
  end

  defp apply_emoji_policy(text, :accept), do: text

  defp apply_emoji_policy(text, :strip),
    do: text |> String.graphemes() |> Enum.reject(&emoji_grapheme?/1) |> Enum.join()

  defp emoji_grapheme?(grapheme),
    do: grapheme |> String.to_charlist() |> Enum.any?(&emoji_codepoint?/1)

  defp codepoints(graphemes) do
    graphemes
    |> Enum.flat_map(&String.to_charlist/1)
    |> Enum.filter(&emoji_codepoint?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp control?(c) when c in [?\n, ?\r], do: false
  defp control?(c), do: c < 0x20 or c in 0x7F..0x9F
end
