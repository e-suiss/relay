defmodule Relay.Templates.Samples do
  @moduledoc """
  Sample data of the preview and of the publication gate (TP-38, TP-47), in priority order: the schema's `examples`, the most recent accepted real events of the workflow masked at preview time, and automatic boundary values.

  Masking keeps the shape and the real length: in a string every letter becomes `X` or `x` by its case (Turkish letters included), every digit `0`, and every other character stays, so the code point and grapheme counts do not change (`"Mehmet Yılmaz"` becomes `"Xxxxxx Xxxxxx"`). Enum and `format: date-time` strings, numbers, booleans and null are kept. The masked value is never stored.

  The boundary samples fill every declared property: `max` (strings at `maxLength`, arrays at `maxItems`, numbers at `maximum`), `min` (empty or `minLength` strings, `minItems` arrays, numbers at `minimum`), and `turkish`, `emoji` and `rtl` (strings of Turkish letters, emoji and Arabic text up to `maxLength`).
  """

  @type sample :: {String.t(), map()}
  @type source :: :example | :real_event | :boundary

  @real_events 20
  @real_event_days 7
  @default_max_items 10
  @max_items_cap 1_000
  @default_string_length 64
  @turkish "Çağrı Iğdır Şükrü İnönü Gülşen Öztürk "
  @emoji "Ali 🎉😀👍🏽 "
  @rtl "مرحبا بالعالم "
  @sample_at "2026-09-30T23:59:59Z"
  @sample_date "2026-09-30"
  @sample_time "23:59:59"
  @variants ~w(max min turkish emoji rtl)

  # TP-47
  @doc "How many of the most recent accepted real events the preview samples, and over how many days."
  @spec real_event_window() :: %{count: pos_integer(), days: pos_integer()}
  def real_event_window, do: %{count: @real_events, days: @real_event_days}

  # TP-38
  @doc "The samples of a preview in priority order: schema examples, masked real events (at most 20), boundary values."
  @spec sources(map(), [map()]) :: [{source(), String.t(), map()}]
  def sources(schema, real_events) when is_map(schema) and is_list(real_events) do
    examples = for {name, data} <- examples(schema), do: {:example, name, data}

    real =
      real_events
      |> Enum.take(@real_events)
      |> Enum.with_index(1)
      |> Enum.map(fn {event, index} -> {:real_event, "real_#{index}", mask(event, schema)} end)

    boundary = for {name, data} <- boundary(schema), do: {:boundary, name, data}
    examples ++ real ++ boundary
  end

  # TP-38
  @doc "The schema's top-level `examples` that are objects."
  @spec examples(map()) :: [sample()]
  def examples(schema) when is_map(schema) do
    schema
    |> Map.get("examples", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {example, index} -> {"example_#{index}", example} end)
  end

  # TP-47
  @doc "Masks a real event against its schema, keeping its shape and lengths."
  @spec mask(term(), map()) :: term()
  def mask(value, schema) when is_map(schema), do: mask(value, schema, schema, 0)

  defp mask(value, _schema, _root, depth) when depth > 64, do: value

  defp mask(map, schema, root, depth) when is_map(map) do
    schema = deref(schema, root)
    properties = Map.get(schema, "properties", %{})

    Map.new(map, fn {key, item} ->
      {key, mask(item, Map.get(properties, key, %{}), root, depth + 1)}
    end)
  end

  defp mask(list, schema, root, depth) when is_list(list) do
    items = schema |> deref(root) |> Map.get("items", %{})
    Enum.map(list, &mask(&1, items, root, depth + 1))
  end

  defp mask(string, schema, root, _depth) when is_binary(string) do
    schema = deref(schema, root)

    if Map.has_key?(schema, "enum") or Map.has_key?(schema, "const") or
         schema["format"] == "date-time",
       do: string,
       else: mask_string(string)
  end

  defp mask(value, _schema, _root, _depth), do: value

  # TP-47
  @doc "Masks a string: letters become `X`/`x` by case, digits `0`, other characters stay."
  @spec mask_string(String.t()) :: String.t()
  def mask_string(string) when is_binary(string) do
    string
    |> String.codepoints()
    |> Enum.map_join(&mask_codepoint/1)
  end

  defp mask_codepoint(codepoint) do
    cond do
      Regex.match?(~r/^[\p{Lu}\p{Lt}]$/u, codepoint) -> "X"
      Regex.match?(~r/^\p{L}$/u, codepoint) -> "x"
      Regex.match?(~r/^\p{Nd}$/u, codepoint) -> "0"
      true -> codepoint
    end
  end

  # TP-38
  @doc "The automatic boundary samples of a schema, by variant name."
  @spec boundary(map()) :: [sample()]
  def boundary(schema) when is_map(schema) do
    for variant <- @variants do
      data =
        case generate(schema, schema, variant, 0) do
          %{} = data -> data
          _ -> %{}
        end

      {variant, data}
    end
  end

  defp generate(_schema, _root, _variant, depth) when depth > 32, do: nil

  defp generate(schema, root, variant, depth) do
    schema = deref(schema, root)

    cond do
      Map.has_key?(schema, "const") -> schema["const"]
      enum?(schema) -> enum(schema["enum"], variant)
      money?(schema) -> money(schema, variant)
      true -> typed(primary_type(schema), schema, root, variant, depth)
    end
  end

  defp typed("object", schema, root, variant, depth), do: object(schema, root, variant, depth)
  defp typed("array", schema, root, variant, depth), do: array(schema, root, variant, depth)
  defp typed("string", schema, _root, variant, _depth), do: string(schema, variant)
  defp typed("integer", schema, _root, variant, _depth), do: integer(schema, variant)
  defp typed("number", schema, _root, variant, _depth), do: number(schema, variant)
  defp typed("boolean", _schema, _root, variant, _depth), do: variant != "min"
  defp typed(_type, schema, root, variant, depth), do: combined(schema, root, variant, depth)

  defp enum?(schema), do: is_list(schema["enum"]) and schema["enum"] != []

  defp primary_type(schema) do
    case schema["type"] do
      nil -> if Map.has_key?(schema, "properties"), do: "object", else: nil
      types -> types |> List.wrap() |> Enum.find(&(&1 != "null"))
    end
  end

  defp combined(schema, root, variant, depth) do
    case Enum.find_value(["allOf", "anyOf", "oneOf"], &List.first(List.wrap(schema[&1]))) do
      nil -> nil
      subschema -> generate(subschema, root, variant, depth + 1)
    end
  end

  defp enum(values, "max"), do: Enum.max_by(values, &length_of/1)
  defp enum(values, "min"), do: Enum.min_by(values, &length_of/1)
  defp enum([first | _], _variant), do: first

  defp length_of(value) when is_binary(value), do: String.length(value)
  defp length_of(value), do: value |> inspect() |> String.length()

  defp object(schema, root, variant, depth) do
    for {key, child} <- Map.get(schema, "properties", %{}), is_map(child), into: %{} do
      {key, generate(child, root, variant, depth + 1)}
    end
  end

  defp array(schema, root, variant, depth) do
    min = Map.get(schema, "minItems", 0)
    max = schema |> Map.get("maxItems", @default_max_items) |> min(@max_items_cap)

    count =
      case variant do
        "max" -> max
        "min" -> min
        _ -> min(max(min, 1), max)
      end

    items = Map.get(schema, "items", %{})
    List.duplicate(generate(items, root, variant, depth + 1), count)
  end

  defp string(schema, variant) do
    case schema["format"] do
      "date-time" -> @sample_at
      "date" -> @sample_date
      "time" -> @sample_time
      "email" -> email(schema, variant)
      _ -> text(schema, variant)
    end
  end

  defp text(schema, variant) do
    min = Map.get(schema, "minLength", 0)
    max = Map.get(schema, "maxLength", max(min, @default_string_length))

    case variant do
      "max" -> fill("x", max)
      "min" -> fill("x", min)
      "turkish" -> fill(@turkish, max)
      "emoji" -> fill(@emoji, max)
      "rtl" -> fill(@rtl, max)
    end
  end

  defp email(schema, variant) do
    domain = "@example.com"
    max = Map.get(schema, "maxLength", @default_string_length)
    local = if variant == "min", do: 1, else: max(max - String.length(domain), 1)
    fill("x", local) <> domain
  end

  defp fill(_pattern, 0), do: ""

  defp fill(pattern, length) do
    codepoints = String.codepoints(pattern)

    codepoints
    |> Stream.cycle()
    |> Enum.take(length)
    |> Enum.join()
  end

  defp money?(schema) do
    properties = Map.get(schema, "properties", %{})
    is_map(properties["amount"]) and is_map(properties["currency"])
  end

  defp money(schema, variant) do
    properties = schema["properties"]
    amount = properties["amount"]
    length = Map.get(amount, "maxLength", 12)

    amount =
      if variant == "min",
        do: "0.00",
        else: fill("9", max(length - 3, 1)) <> ".99"

    currency =
      case properties["currency"] do
        %{"enum" => [code | _]} -> code
        %{"const" => code} -> code
        _ -> "TRY"
      end

    %{"amount" => amount, "currency" => currency}
  end

  defp integer(schema, "min"), do: Map.get(schema, "minimum", 0)
  defp integer(schema, _variant), do: Map.get(schema, "maximum", 999_999)

  defp number(schema, "min"), do: Map.get(schema, "minimum", 0)
  defp number(schema, _variant), do: Map.get(schema, "maximum", 999_999.99)

  defp deref(schema, root), do: deref(schema, root, 0)

  defp deref(%{"$ref" => "#/" <> pointer}, root, depth) when depth < 32 do
    pointer
    |> String.split("/")
    |> Enum.map(&unescape_pointer/1)
    |> Enum.reduce_while(root, fn key, node ->
      case node do
        %{^key => child} -> {:cont, child}
        _ -> {:halt, nil}
      end
    end)
    |> case do
      %{} = target -> deref(target, root, depth + 1)
      _ -> %{}
    end
  end

  defp deref(%{"$ref" => "#"}, root, depth) when depth < 32, do: root
  defp deref(schema, _root, _depth) when is_map(schema), do: schema
  defp deref(_schema, _root, _depth), do: %{}

  defp unescape_pointer(key), do: key |> String.replace("~1", "/") |> String.replace("~0", "~")
end
