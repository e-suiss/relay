defmodule Relay.Templates.Sms do
  @moduledoc """
  The SMS measurement of one rendered message (TP-18, TP-19, TP-53, CH-48, CH-49).

  `plan/2` takes the rendered body and the mandatory legal text and returns the text to send with its planned encoding, segments, characters and units. The legal text is never transliterated or normalised, and its units are reserved before the body budget (TP-19). Because the provider catalogue arrives in stage 6, every provider is `turkish_single_shift: unverified` (TP-53), so the plan also reports the encoding and segments on an unverified provider, where `GSM7_TR` becomes `UCS2`.

  Options of `plan/2`:

    * `:policy` – `:transliterate`, `:turkish_shift` (default) or `:ucs2` (TP-18). Text the default alphabet carries is always `GSM7`; the policy decides what happens to text it does not carry.
    * `:message_class` – the class of the category (`"security"`, `"transactional"`, …). The body of a `security` message is always transliterated (CH-49).
    * `:legal` – the rendered mandatory legal text (sender identity, commercial mark, opt-out instruction), default `""`.
    * `:separator` – placed between a non-empty body and a non-empty legal text, default `"\\n"`.
    * `:reserved` – units lost to the operator prefix of a TR SMS with a sender header (CH-48), default `0`.
    * `:normalize` – replace typographic characters that force UCS-2 in the body (CH-48), default `false`.
  """

  alias Relay.Templates.Finding
  alias Relay.Templates.Sanitizer
  alias Relay.Templates.Sms.Content
  alias Relay.Templates.Sms.Encoding
  alias Relay.Templates.Sms.Segments
  alias Relay.Templates.Sms.Transliteration

  @type measure :: %{
          encoding: Encoding.t(),
          name: String.t(),
          segments: non_neg_integer(),
          units: non_neg_integer()
        }
  @type forcing :: %{
          codepoint: non_neg_integer(),
          count: pos_integer(),
          normalizable: boolean()
        }
  @type plan :: %{
          text: String.t(),
          body: String.t(),
          legal: String.t(),
          encoding: Encoding.t(),
          name: String.t(),
          segments: non_neg_integer(),
          units: non_neg_integer(),
          characters: non_neg_integer(),
          legal_units: non_neg_integer(),
          body_capacity: non_neg_integer(),
          unverified: measure(),
          ucs2_characters: [forcing()],
          emoji: non_neg_integer(),
          changes: [Sanitizer.change()]
        }

  # TP-18
  # TP-19
  # TP-53
  # CH-48
  # CH-49
  @doc "Sanitises, optionally normalises and transliterates the body, joins the legal text and measures the message; see the module documentation for the options."
  @spec plan(binary(), keyword()) :: plan()
  def plan(body, opts \\ []) do
    policy = Keyword.get(opts, :policy, :turkish_shift)
    reserved = Keyword.get(opts, :reserved, 0)
    transliterate = Transliteration.applies?(class(opts), :body, policy == :transliterate)
    normalize = Keyword.get(opts, :normalize, false)

    {body, body_changes} =
      Sanitizer.pipe(body, [
        &Content.sanitize(&1, "body"),
        fn t -> optional(t, normalize, &Transliteration.normalize/1) end,
        fn t -> optional(t, transliterate, &Transliteration.transliterate/1) end
      ])

    {legal, legal_changes} = Content.sanitize(Keyword.get(opts, :legal, ""), "legal")
    separator = Keyword.get(opts, :separator, "\n")
    tail = if body != "" and legal != "", do: separator <> legal, else: legal
    text = body <> tail
    encoding = Encoding.choose(text, policy)
    planned = measure(text, encoding, reserved)
    legal_units = unit_sum(tail, encoding)
    capacity = Segments.capacity(encoding, max(planned.segments, 1), reserved + legal_units)

    Map.merge(planned, %{
      text: text,
      body: body,
      legal: legal,
      characters: String.length(text),
      legal_units: legal_units,
      body_capacity: capacity,
      unverified: unverified(text, planned, reserved),
      ucs2_characters: forcing(text, policy),
      emoji: length(Content.emoji(text)),
      changes: Sanitizer.with_field(body_changes, "body") ++ legal_changes
    })
  end

  # CH-48
  # CH-75
  @doc "Measures a rendered SMS text for one provider: the cheapest of the `allowed` encodings (`:gsm7`, `:gsm7_tr`, `:ucs2`) that carries the text, with its segments and units after `reserved` units; `:error` when none of them carries it."
  @spec measure(String.t(), [Encoding.t()], non_neg_integer()) :: {:ok, measure()} | :error
  def measure(text, allowed, reserved) when is_binary(text) and is_list(allowed) do
    case Enum.find([:gsm7, :gsm7_tr, :ucs2], &(&1 in allowed and Encoding.fits?(text, &1))) do
      nil -> :error
      encoding -> {:ok, measure(text, encoding, reserved)}
    end
  end

  # TP-18
  # TP-32
  # CH-48
  @doc "Warning findings for a plan: characters that force UCS-2, emoji, and more segments than `:max_segments` when given."
  @spec findings(plan(), keyword()) :: [Finding.t()]
  def findings(plan, opts \\ []) do
    fields = [channel: :sms, locale: Keyword.get(opts, :locale), pointer: "/body"]
    max_segments = Keyword.get(opts, :max_segments)
    ucs2(plan, fields) ++ emoji(plan, fields) ++ segments(plan, fields, max_segments)
  end

  defp ucs2(%{ucs2_characters: []}, _fields), do: []

  defp ucs2(plan, fields) do
    detail = %{characters: plan.ucs2_characters, encoding: plan.name}
    [Finding.new(:sms_ucs2_characters, :warning, [detail: detail] ++ fields)]
  end

  defp emoji(%{emoji: 0}, _fields), do: []

  defp emoji(plan, fields),
    do: [Finding.new(:sms_emoji_value, :warning, [detail: %{count: plan.emoji}] ++ fields)]

  defp segments(%{segments: count, name: name}, fields, limit)
       when is_integer(limit) and count > limit do
    detail = %{segments: count, limit: limit, encoding: name}
    [Finding.new(:sms_segments, :warning, [detail: detail] ++ fields)]
  end

  defp segments(_plan, _fields, _limit), do: []

  defp class(opts), do: Keyword.get(opts, :message_class, "")

  defp optional(text, true, fun), do: fun.(text)
  defp optional(text, _off, _fun), do: {text, []}

  defp measure(text, encoding, reserved) do
    {:ok, units} = Encoding.units(text, encoding)

    %{
      encoding: encoding,
      name: Encoding.name(encoding),
      segments: Segments.count(units, encoding, reserved),
      units: Enum.sum(units)
    }
  end

  defp unverified(text, %{encoding: :gsm7_tr}, reserved), do: measure(text, :ucs2, reserved)
  defp unverified(_text, planned, _reserved), do: planned

  defp unit_sum(text, encoding) do
    {:ok, units} = Encoding.units(text, encoding)
    Enum.sum(units)
  end

  defp forcing(text, policy) do
    table = if policy == :ucs2, do: :gsm7, else: :gsm7_tr

    for entry <- Encoding.unsupported(text, table),
        do: Map.put(entry, :normalizable, Transliteration.normalizable?(entry.codepoint))
  end
end
