defmodule Relay.Templates.Lint.Accessibility do
  @moduledoc """
  Accessibility and content lint of the publish gate (TP-34). Every finding is a warning.

    * E-mail (`email/2`): the `html` element has a `lang` attribute, every `img` has an `alt` attribute (an empty `alt` marks a decorative image), the message is not made of images only, the plain text body is present, and an element whose inline style sets both a text and a background colour reaches the WCAG AA contrast ratio of 4.5.
    * Notification text (`first_line/2`): the meaning is in the first line, so the first line is neither empty nor only a greeting ("önemli bilgiyi öne al").
    * Lock screen (`lock_screen/3`): fields that can show on a lock screen carry no sensitive dataset term (`Relay.Templates.Lint.Terms`).
  """

  alias Relay.Templates.Finding
  alias Relay.Templates.Lint.Terms

  @type rgb :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @min_contrast 4.5
  @greetings ~w(merhaba selam sayın değerli hello hi hey dear greetings)
  @greeting_max 30

  # TP-34
  @doc ~s[E-mail lint over the rendered `"html"` and `"text"` fields; `opts` takes `:locale`.]
  @spec email(map(), keyword()) :: [Finding.t()]
  def email(fields, opts \\ []) do
    html = string(fields, "html")
    text = string(fields, "text")
    base = [channel: :email, locale: Keyword.get(opts, :locale)]

    [
      !lang?(html) && {:a11y_lang, "/html", %{}},
      missing_alt(html),
      image_only?(html) && {:a11y_image_only, "/html", %{}},
      String.trim(text) == "" && {:a11y_plain_text, "/text", %{}},
      low_contrast(html)
    ]
    |> Enum.filter(&is_tuple/1)
    |> Enum.map(fn {check, pointer, detail} ->
      Finding.new(check, :warning, [pointer: pointer, detail: detail] ++ base)
    end)
  end

  # TP-34
  @doc "First line lint of a notification text; `opts` takes `:channel`, `:locale` and `:pointer`."
  @spec first_line(String.t(), keyword()) :: [Finding.t()]
  def first_line(text, opts \\ []) do
    locale = Keyword.get(opts, :locale)
    line = text |> String.split(["\r\n", "\n", "\r"], parts: 2) |> hd() |> String.trim()

    if line == "" or greeting?(line, locale) do
      fields = [channel: Keyword.get(opts, :channel), locale: locale]
      [Finding.new(:a11y_first_line, :warning, [pointer: Keyword.get(opts, :pointer)] ++ fields)]
    else
      []
    end
  end

  # TP-21
  # TP-34
  @doc ~s[Lock screen lint: `fields` maps a field name (`"title"`, `"body"`, `"lock_screen_body"`) to its static text; `opts` takes `:channel` and `:locale`.]
  @spec lock_screen(map(), [Terms.entry()], keyword()) :: [Finding.t()]
  def lock_screen(fields, entries, opts \\ []) do
    locale = Keyword.get(opts, :locale)
    base = [channel: Keyword.get(opts, :channel, :push), locale: locale]

    fields
    |> Enum.sort()
    |> Enum.flat_map(fn {name, text} ->
      case Terms.scan([text], entries, locale) do
        [] -> []
        found -> [lock_screen_finding(name, found, base)]
      end
    end)
  end

  defp lock_screen_finding(name, found, base) do
    fields = [pointer: "/#{name}", detail: %{terms: found}] ++ base
    Finding.new(:a11y_lock_screen, :warning, fields)
  end

  # TP-34
  @doc "The WCAG contrast ratio of two `{r, g, b}` colours (0–255), from 1.0 to 21.0."
  @spec contrast(rgb(), rgb()) :: float()
  def contrast(first, second) do
    [high, low] = Enum.sort([luminance(first), luminance(second)], :desc)
    (high + 0.05) / (low + 0.05)
  end

  # TP-34
  @doc "Parses a CSS colour value: `#rgb`, `#rrggbb` or `rgb(r, g, b)`; `nil` otherwise."
  @spec parse_color(String.t()) :: rgb() | nil
  def parse_color(value) do
    value = value |> String.downcase() |> String.replace(~r/\s+/, "")

    Enum.find_value(color_formats(), fn {pattern, convert} ->
      case Regex.run(pattern, value, capture: :all_but_first) do
        nil -> nil
        parts -> parts |> Enum.map(convert) |> List.to_tuple()
      end
    end)
  end

  defp color_formats do
    [
      {~r/\A#([0-9a-f])([0-9a-f])([0-9a-f])\z/, &String.to_integer(&1 <> &1, 16)},
      {~r/\A#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})\z/, &String.to_integer(&1, 16)},
      {~r/\Argba?\((\d{1,3}),(\d{1,3}),(\d{1,3})[,)]/, &min(String.to_integer(&1), 255)}
    ]
  end

  defp lang?(html), do: Regex.match?(~r/<html\b[^>]*\slang\s*=\s*["']?[A-Za-z]/i, html)

  defp luminance({r, g, b}) do
    0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
  end

  defp channel(value) do
    c = value / 255
    if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
  end

  defp missing_alt(html) do
    count =
      ~r/<img\b[^>]*>/i
      |> Regex.scan(html)
      |> Enum.count(fn [tag] -> not Regex.match?(~r/\salt\s*=/i, tag) end)

    count > 0 && {:a11y_img_alt, "/html", %{count: count}}
  end

  defp image_only?(html) do
    visible =
      html
      |> String.replace(~r/<(head|style|script)\b.*?<\/\1\s*>/is, " ")
      |> String.replace(~r/<[^>]*>/s, " ")
      |> String.replace(~r/&(nbsp|#160|#xa0|zwnj|#8204);/i, " ")
      |> String.trim()

    visible == "" and Regex.match?(~r/<img\b/i, html)
  end

  defp low_contrast(html) do
    ratios =
      ~r/\sstyle\s*=\s*(?:"([^"]*)"|'([^']*)')/i
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(&style_contrast(Enum.join(&1)))
      |> Enum.filter(&(is_float(&1) and &1 < @min_contrast))

    case ratios do
      [] ->
        false

      _low ->
        lowest = Float.round(Enum.min(ratios), 2)
        detail = %{count: length(ratios), lowest: lowest, minimum: @min_contrast}
        {:a11y_contrast, "/html", detail}
    end
  end

  defp style_contrast(style) do
    declarations =
      for declaration <- String.split(style, ";"),
          [property, value] <- [String.split(declaration, ":", parts: 2)],
          into: %{},
          do: {property |> String.trim() |> String.downcase(), value}

    foreground = color(declarations["color"])
    background = color(declarations["background-color"] || declarations["background"])

    if foreground && background, do: contrast(foreground, background), else: nil
  end

  defp color(nil), do: nil

  defp color(value) do
    value
    |> String.split(~r/\s+(?![^(]*\))/, trim: true)
    |> Enum.find_value(&parse_color/1)
  end

  defp greeting?(line, locale) do
    words = line |> Terms.fold(locale) |> String.split(~r/[^\p{L}]+/u, trim: true)
    first = List.first(words)
    short = String.length(line) <= @greeting_max
    short and Enum.any?(@greetings, &(Terms.fold(&1, locale) == first))
  end

  defp string(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) -> value
      _absent -> ""
    end
  end
end
