defmodule Relay.Templates.Filters do
  @moduledoc """
  The complete filter set of tenant templates (TP-45). No other filter exists: the standard Liquid filters of Solid are never reached, arithmetic and `escape` are absent.

  Text: `upcase`, `downcase`, `capitalize` (locale aware; Turkish and Azerbaijani İ/i and I/ı, TP-28), `strip`, `lstrip`, `rstrip`, `truncate` (graphemes, constant length), `replace`, `prepend`, `append`, `default`, `url_encode`, `sms_safe`. Arrays: `size`, `first`, `last`, `join`. Localisation in the recipient's locale and time zone (TP-27): `number`, `percent`, `currency` (`{amount, currency}`, TP-16), `datetime`, `date`, `time`, `plural` and `icu` (classic ICU MessageFormat). Trust: `raw`, only when the template's `allow_raw` flag is set (TP-24).

  Values arrive escaped for the channel (`Relay.Templates.Escape`); a text filter reverses the escaping of its inputs, applies itself and escapes its result again, so escaping is applied exactly once. The internal output filter ends every output tag: it refuses to print an object and isolates the value in right-to-left locales (TP-29).
  """

  alias Relay.Templates.Cldr, as: Backend
  alias Relay.Templates.Cldr.Number.Cardinal
  alias Relay.Templates.Cldr.Number.Ordinal
  alias Relay.Templates.Escape

  @type state :: %{
          required(:locale) => String.t(),
          required(:tag) => Cldr.LanguageTag.t(),
          required(:time_zone) => String.t(),
          required(:escape) => Escape.mode(),
          required(:isolate) => boolean(),
          required(:allow_raw) => boolean()
        }

  @output "relay:output"

  @arities %{
    "upcase" => 0..0,
    "downcase" => 0..0,
    "capitalize" => 0..0,
    "strip" => 0..0,
    "lstrip" => 0..0,
    "rstrip" => 0..0,
    "truncate" => 1..2,
    "replace" => 2..2,
    "prepend" => 1..1,
    "append" => 1..1,
    "default" => 1..1,
    "url_encode" => 0..0,
    "sms_safe" => 0..0,
    "size" => 0..0,
    "first" => 0..0,
    "last" => 0..0,
    "join" => 0..1,
    "number" => 0..1,
    "percent" => 0..1,
    "currency" => 0..0,
    "datetime" => 0..1,
    "date" => 0..1,
    "time" => 0..1,
    "plural" => 0..0,
    "icu" => 0..0,
    "raw" => 0..0
  }

  @named ~w(plural icu)
  @plural_keys ~w(zero one two few many other)
  @styles %{"short" => :short, "medium" => :medium, "long" => :long, "full" => :full}
  @turkic ~w(tr az)
  @categories %{zero: "zero", one: "one", two: "two", few: "few", many: "many", other: "other"}
  @invisible ~r/[\x{0000}-\x{0009}\x{000B}-\x{001F}\x{007F}-\x{009F}\x{061C}\x{180E}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2069}\x{FEFF}]/u
  @typography [
    {~r/[\x{201C}\x{201D}\x{201E}\x{201F}\x{00AB}\x{00BB}]/u, "\""},
    {~r/[\x{2018}\x{2019}\x{201A}\x{201B}]/u, "'"},
    {~r/[\x{2010}-\x{2015}\x{2212}]/u, "-"},
    {~r/\x{2026}/u, "..."},
    {~r/[\x{00A0}\x{2007}\x{2009}\x{200A}\x{202F}]/u, " "}
  ]

  # TP-45
  @doc "The names of the filters a template may use."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@arities)

  # TP-45
  @doc "The number of positional arguments a filter accepts; nil for a name outside the set."
  @spec arity(String.t()) :: Range.t() | nil
  def arity(name), do: Map.get(@arities, name)

  # TP-45
  @doc "Whether a filter takes named arguments (`plural`, `icu`); no other filter does."
  @spec named?(String.t()) :: boolean()
  def named?(name), do: name in @named

  @doc "The plural shorthand keys; `zero` is the explicit `=0` match, the others are CLDR categories."
  @spec plural_keys() :: [String.t()]
  def plural_keys, do: @plural_keys

  @doc "The date and time styles of `datetime`, `date` and `time`."
  @spec styles() :: [String.t()]
  def styles, do: Map.keys(@styles)

  @doc "The name of the internal filter that ends every output tag; a template cannot name it."
  @spec output_filter() :: String.t()
  def output_filter, do: @output

  # TP-45
  # TP-24
  # TP-28
  @doc "Applies a filter the way Solid's custom filter callback expects; a failure is an argument error and is never handed to the standard filters."
  @spec run(String.t(), [term()], state()) :: {:ok, term()} | {:error, Exception.t(), nil}
  def run(name, [input | args], state) do
    case call(name, input, args, state) do
      {:ok, value} -> {:ok, value}
      {:error, message} -> {:error, %Solid.ArgumentError{message: message}, nil}
    end
  rescue
    _exception -> {:error, %Solid.ArgumentError{message: "filter #{name} failed"}, nil}
  end

  def run(name, [], _state),
    do: {:error, %Solid.ArgumentError{message: "filter #{name} failed"}, nil}

  defp call(@output, input, [], state), do: output(input, state)
  defp call("upcase", input, [], state), do: text(input, state, &String.upcase(&1, mode(state)))

  defp call("downcase", input, [], state),
    do: text(input, state, &String.downcase(&1, mode(state)))

  defp call("capitalize", input, [], state),
    do: text(input, state, &String.capitalize(&1, mode(state)))

  defp call("strip", input, [], state), do: text(input, state, &String.trim/1)
  defp call("lstrip", input, [], state), do: text(input, state, &String.trim_leading/1)
  defp call("rstrip", input, [], state), do: text(input, state, &String.trim_trailing/1)

  defp call("truncate", input, [length], state),
    do: call("truncate", input, [length, "..."], state)

  defp call("truncate", input, [length, ellipsis], state)
       when is_integer(length) and length >= 0 and is_binary(ellipsis) do
    ellipsis = decode(ellipsis, state)
    text(input, state, &truncate(&1, length, ellipsis))
  end

  defp call("replace", input, [pattern, replacement], state) do
    with {:ok, pattern} <- string(pattern, state),
         {:ok, replacement} <- string(replacement, state) do
      text(input, state, &replace(&1, pattern, replacement))
    end
  end

  defp call("prepend", input, [prefix], state) do
    with {:ok, prefix} <- string(prefix, state), do: text(input, state, &(prefix <> &1))
  end

  defp call("append", input, [suffix], state) do
    with {:ok, suffix} <- string(suffix, state), do: text(input, state, &(&1 <> suffix))
  end

  defp call("default", input, [fallback], _state) do
    if input in [nil, false, ""] or input == [], do: {:ok, fallback}, else: {:ok, input}
  end

  defp call("url_encode", input, [], state), do: text(input, state, &URI.encode_www_form/1)
  defp call("sms_safe", input, [], state), do: text(input, state, &sms_safe/1)
  defp call("size", nil, [], _state), do: {:ok, 0}
  defp call("size", list, [], _state) when is_list(list), do: {:ok, length(list)}
  defp call("size", map, [], _state) when is_map(map), do: {:ok, map_size(map)}

  defp call("size", input, [], state) do
    with {:ok, string} <- string(input, state), do: {:ok, String.length(string)}
  end

  defp call("first", list, [], _state) when is_list(list), do: {:ok, List.first(list)}
  defp call("last", list, [], _state) when is_list(list), do: {:ok, List.last(list)}

  defp call(edge, input, [], state) when edge in ["first", "last"] and is_binary(input) do
    pick = if edge == "first", do: &String.first/1, else: &String.last/1
    text(input, state, &(pick.(&1) || ""))
  end

  defp call("join", list, [], state), do: call("join", list, [" "], state)

  defp call("join", list, [separator], state) when is_list(list) do
    with {:ok, separator} <- string(separator, state),
         {:ok, items} <- strings(list, state) do
      {:ok, encode(Enum.join(items, separator), state)}
    end
  end

  defp call("number", input, [], state), do: number(input, [], state)

  defp call("number", input, [digits], state) when is_integer(digits) and digits in 0..10,
    do: number(input, [fractional_digits: digits], state)

  defp call("percent", input, [], state), do: number(input, [format: :percent], state)

  defp call("percent", input, [digits], state) when is_integer(digits) and digits in 0..10,
    do: number(input, [format: :percent, fractional_digits: digits], state)

  defp call("currency", %{"amount" => amount, "currency" => code}, [], state)
       when is_binary(amount) and is_binary(code) do
    with {:ok, decimal} <- decimal(amount) do
      number(decimal, [format: :currency, currency: code], state)
    end
  end

  defp call(kind, input, [], state) when kind in ["datetime", "date"],
    do: call(kind, input, ["medium"], state)

  defp call("time", input, [], state), do: call("time", input, ["short"], state)

  defp call(kind, input, [style], state) when kind in ["datetime", "date", "time"] do
    with {:ok, style} <- style(kind, style),
         {:ok, value} <- temporal(kind, input, state),
         {:ok, formatted} <- format_temporal(kind, value, style, state) do
      {:ok, encode(formatted, state)}
    end
  end

  defp call("plural", input, [named], state) when is_map(named), do: plural(input, named, state)
  defp call("icu", input, [named], state) when is_map(named), do: icu(input, named, state)

  defp call("raw", input, [], %{allow_raw: true} = state) when is_binary(input),
    do: {:ok, Escape.unescape(input, state.escape)}

  defp call("raw", _input, [], %{allow_raw: false}),
    do: {:error, "raw is not allowed in this template"}

  defp call(name, _input, _args, _state), do: {:error, "invalid input or arguments for #{name}"}

  defp output(nil, _state), do: {:ok, ""}
  defp output(map, _state) when is_map(map), do: {:error, "an object cannot be printed"}

  defp output(list, state) when is_list(list) do
    if Enum.any?(list, &(is_map(&1) or is_list(&1))),
      do: {:error, "an object cannot be printed"},
      else: list |> Enum.map_join(&scalar/1) |> isolate(state)
  end

  defp output(value, state), do: value |> scalar() |> isolate(state)

  defp isolate(string, %{isolate: true}), do: {:ok, Escape.isolate(string)}
  defp isolate(string, _state), do: {:ok, string}

  defp scalar(nil), do: ""
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(value) when is_float(value), do: Float.to_string(value)
  defp scalar(value) when is_boolean(value), do: Atom.to_string(value)

  defp mode(%{locale: locale}) do
    language = locale |> String.split("-", parts: 2) |> hd() |> String.downcase()
    if language in @turkic, do: :turkic, else: :default
  end

  defp text(input, state, fun) do
    with {:ok, string} <- string(input, state), do: {:ok, encode(fun.(string), state)}
  end

  defp string(nil, _state), do: {:ok, ""}
  defp string(value, state) when is_binary(value), do: {:ok, decode(value, state)}
  defp string(value, _state) when is_integer(value) or is_float(value), do: {:ok, scalar(value)}
  defp string(value, _state) when is_boolean(value), do: {:ok, scalar(value)}
  defp string(_value, _state), do: {:error, "expected a string"}

  defp strings(list, state) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case string(item, state) do
        {:ok, string} -> {:cont, {:ok, [string | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp decode(value, %{escape: mode}), do: Escape.unescape(value, mode)
  defp encode(value, %{escape: mode}), do: Escape.escape(value, mode)

  defp truncate(string, length, ellipsis) do
    if String.length(string) <= length do
      string
    else
      keep = max(length - String.length(ellipsis), 0)
      String.slice(string, 0, keep) <> ellipsis
    end
  end

  defp replace(string, "", _replacement), do: string
  defp replace(string, pattern, replacement), do: String.replace(string, pattern, replacement)

  # TP-19
  @doc "Removes control, zero-width and direction control characters and replaces typographic punctuation with its GSM 7-bit counterpart."
  @spec sms_safe(String.t()) :: String.t()
  def sms_safe(string) do
    string = string |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
    string = Regex.replace(@invisible, string, "")

    Enum.reduce(@typography, string, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  defp number(input, options, state) do
    with {:ok, value} <- numeric(input),
         {:ok, formatted} <- Backend.Number.to_string(value, [locale: state.tag] ++ options) do
      {:ok, encode(formatted, state)}
    else
      {:error, {_exception, message}} when is_binary(message) -> {:error, message}
      {:error, message} -> {:error, message}
    end
  end

  defp numeric(value) when is_integer(value) or is_float(value), do: {:ok, value}
  defp numeric(%Decimal{} = value), do: {:ok, value}
  defp numeric(value) when is_binary(value), do: decimal(value)
  defp numeric(_value), do: {:error, "expected a number"}

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> finite(decimal)
      _ -> {:error, "expected a decimal number"}
    end
  end

  defp finite(decimal) do
    if Decimal.inf?(decimal) or Decimal.nan?(decimal),
      do: {:error, "expected a decimal number"},
      else: {:ok, decimal}
  end

  defp temporal("date", input, state) when is_binary(input) do
    case Date.from_iso8601(input) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> with {:ok, at} <- local(input, state), do: {:ok, DateTime.to_date(at)}
    end
  end

  defp temporal(_kind, input, state) when is_binary(input), do: local(input, state)
  defp temporal(kind, _input, _state), do: {:error, "#{kind} expects an ISO 8601 date-time"}

  defp local(input, state) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(input),
         {:ok, %DateTime{} = local} <- DateTime.shift_zone(at, state.time_zone) do
      {:ok, local}
    else
      _ -> {:error, "expected an ISO 8601 date-time"}
    end
  end

  defp format_temporal(kind, value, style, state) do
    options = [format: style, locale: state.tag]

    result =
      case kind do
        "datetime" -> Backend.DateTime.to_string(value, options)
        "date" -> Backend.Date.to_string(value, options)
        "time" -> Backend.Time.to_string(value, options)
      end

    case result do
      {:ok, formatted} -> {:ok, formatted}
      _ -> {:error, "cannot format the #{kind}"}
    end
  end

  # TP-27
  defp plural(input, named, state) do
    with :ok <- plural_keys(named),
         {:ok, count} <- numeric(input),
         {:ok, formatted} <- Backend.Number.to_string(count, locale: state.tag) do
      category = Cardinal.plural_rule(count, state.tag)
      message = if zero?(count), do: named["zero"], else: nil
      message = message || named[Map.fetch!(@categories, category)] || named["other"]
      {:ok, String.replace(message, "#", formatted)}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "cannot format the plural"}
    end
  end

  defp plural_keys(named) do
    cond do
      not Map.has_key?(named, "other") -> {:error, "plural needs an other form"}
      Enum.all?(named, &plural_form?/1) -> :ok
      true -> {:error, "plural takes zero, one, two, few, many and other forms"}
    end
  end

  defp plural_form?({key, value}), do: key in @plural_keys and is_binary(value)

  defp zero?(count) when is_integer(count), do: count == 0
  defp zero?(count) when is_float(count), do: count == 0.0
  defp zero?(%Decimal{} = count), do: Decimal.eq?(count, 0)

  # TP-27
  defp icu(message, bindings, state) when is_binary(message) do
    trimmed = String.trim_leading(message)

    if String.starts_with?(trimmed, ".") or String.starts_with?(trimmed, "{{") do
      {:error, "icu takes classic ICU MessageFormat"}
    else
      options = [backend: Backend, locale: state.tag, allow_positional_args: false]

      case Cldr.Message.format(message, bindings, options) do
        {:ok, formatted} -> {:ok, formatted}
        {:error, _reason} -> {:error, "cannot format the ICU message"}
      end
    end
  end

  defp icu(_message, _bindings, _state), do: {:error, "icu expects a message"}

  # TP-27
  # TP-59
  @doc "The plural and select forms an ICU message lacks for a locale: `other` and every CLDR category of the locale, in every `plural`, `selectordinal` and `select` argument. An unparsable message or an unsupported locale lacks `other`."
  @spec icu_categories_missing(String.t(), String.t()) :: [String.t()]
  def icu_categories_missing(message, locale) when is_binary(message) and is_binary(locale) do
    with {:ok, tag} <- Backend.language_tag(locale),
         {:ok, parsed} <- Cldr.Message.V1.Parser.parse(message, false) do
      cardinal = categories(Cardinal.plural_rules_for(tag))
      ordinal = categories(Ordinal.plural_rules_for(tag))
      parsed |> missing(cardinal, ordinal) |> Enum.uniq() |> Enum.sort()
    else
      _ -> ["other"]
    end
  end

  defp categories(rules),
    do: Enum.map(rules, fn {category, _rule} -> Atom.to_string(category) end)

  defp missing(list, cardinal, ordinal) when is_list(list),
    do: Enum.flat_map(list, &missing(&1, cardinal, ordinal))

  defp missing({:plural, _arg, _options, forms}, cardinal, ordinal) when is_map(forms),
    do: absent(forms, cardinal) ++ nested(forms, cardinal, ordinal)

  defp missing({:select_ordinal, _arg, _options, forms}, cardinal, ordinal) when is_map(forms),
    do: absent(forms, ordinal) ++ nested(forms, cardinal, ordinal)

  defp missing({:select, _arg, forms}, cardinal, ordinal) when is_map(forms),
    do: absent(forms, []) ++ nested(forms, cardinal, ordinal)

  defp missing(_part, _cardinal, _ordinal), do: []

  defp absent(forms, categories) do
    keys = forms |> Map.keys() |> Enum.map(&to_string/1)
    Enum.reject(["other" | categories], &(&1 in keys))
  end

  defp nested(forms, cardinal, ordinal),
    do: forms |> Map.values() |> Enum.flat_map(&missing(&1, cardinal, ordinal))

  defp style(kind, style) do
    case Map.fetch(@styles, style) do
      {:ok, style} -> {:ok, style}
      :error -> {:error, "unknown #{kind} style"}
    end
  end
end
