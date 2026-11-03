defmodule Relay.Templates.Context do
  @moduledoc """
  The allow-listed render context of one template cell for one channel (TP-5, TP-24).

  Only plain JSON-like data enters: string-keyed maps, lists, strings, numbers, booleans and null. Event data is at the top level; the schema-declared recipient attributes are under `recipient`, the brand variables under `brand`, and the render helpers (for example `legal_footer`, `unsubscribe_url`) are top-level names supplied by the caller. Internal structures, the tenant identity and secrets have no place in it. Data deeper than five levels is cut off, so it cannot be read.

  The context is built for one channel and one escaping mode and every string value is escaped for it (`Relay.Templates.Escape`); a helper given as `{:trusted, string}` is Relay's own output and is not escaped. Rendering checks the channel, so a context is never reused for another channel. In right-to-left locales every printed value is isolated with U+2068 … U+2069, except on SMS (TP-29).

  Variable criticality (TP-14) is applied here: a missing `fallback` variable takes its declared default and is counted, a missing `optional` or `decorative` variable is null, a missing `required` variable stays missing and stops the render.
  """

  alias Relay.Templates.Escape

  @enforce_keys [:channel, :escape, :locale, :tag, :time_zone, :isolate, :vars, :fallbacks]
  defstruct @enforce_keys

  @type channel ::
          :push
          | :web_push
          | :email
          | :sms
          | :voice
          | :whatsapp
          | :slack
          | :teams
          | :telegram
          | :discord
          | :in_app
          | :webhook
  @type part :: :subject | :preheader | :html | :text | :title | :body | :payload
  @type criticality :: :required | :fallback | :optional | :decorative
  @type declaration :: %{required(:class) => criticality(), optional(:default) => term()}
  @type t :: %__MODULE__{
          channel: channel(),
          escape: Escape.mode(),
          locale: String.t(),
          tag: Cldr.LanguageTag.t(),
          time_zone: String.t(),
          isolate: boolean(),
          vars: map(),
          fallbacks: [String.t()]
        }
  @type error :: {:schema_violation, String.t()}

  @channels [
    :push,
    :web_push,
    :email,
    :sms,
    :voice,
    :whatsapp,
    :slack,
    :teams,
    :telegram,
    :discord,
    :in_app,
    :webhook
  ]
  @max_depth 5
  @reserved ~w(recipient brand)
  @rtl ~w(ar arc ckb dv fa he ks ku ps sd syr ug ur yi)

  @doc "The channel types a context can be built for."
  @spec channels() :: [channel()]
  def channels, do: @channels

  @doc "The deepest nested access a template may make and a context keeps."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  # TP-24
  @doc "The escaping mode of a channel part: HTML entities for email HTML, line-break removal for text parts, the JSON encoder for push and webhook, structured fields for the inbox."
  @spec escape_mode(channel(), part() | nil) :: Escape.mode()
  def escape_mode(:email, :html), do: :html
  def escape_mode(:email, _part), do: :text
  def escape_mode(channel, _part) when channel in [:push, :web_push, :webhook], do: :json
  def escape_mode(:in_app, _part), do: :structured
  def escape_mode(channel, _part) when channel in @channels, do: :text

  # TP-29
  @doc "The writing direction of a BCP 47 locale."
  @spec direction(String.t()) :: :ltr | :rtl
  def direction(locale) when is_binary(locale) do
    language = locale |> String.split("-", parts: 2) |> hd() |> String.downcase()
    if language in @rtl, do: :rtl, else: :ltr
  end

  # TP-5
  # TP-14
  # TP-24
  # TP-29
  @doc """
  Builds the context of one render.

  Fields: `:locale` (a supported BCP 47 locale, required), `:time_zone` (an IANA zone, required), `:data` (event data), `:recipient`, `:brand`, `:helpers` (name to string or `{:trusted, string}`), `:variables` (criticality declarations by path, see `Relay.Templates.Variables.criticality/1`), `:schema` (a built `JSV.Root` the event data is validated against) and `:escape` (defaults to `escape_mode(channel, part)` with `:part`).
  """
  @spec new(channel(), keyword()) :: {:ok, t()} | {:error, error()}
  def new(channel, fields) when channel in @channels and is_list(fields) do
    escape = Keyword.get_lazy(fields, :escape, fn -> escape_mode(channel, fields[:part]) end)

    with :ok <- escape_mode?(escape),
         {:ok, locale, tag} <- locale(fields[:locale]),
         {:ok, time_zone} <- time_zone(fields[:time_zone]),
         {:ok, data} <- plain(:data, Keyword.get(fields, :data, %{})),
         {:ok, recipient} <- plain(:recipient, Keyword.get(fields, :recipient, %{})),
         {:ok, brand} <- plain(:brand, Keyword.get(fields, :brand, %{})),
         {:ok, helpers} <- helpers(Keyword.get(fields, :helpers, %{})),
         :ok <- reserved(data, helpers),
         :ok <- validate(data, fields[:schema]) do
      {data, fallbacks} = criticality(data, Keyword.get(fields, :variables, %{}))

      vars =
        data
        |> Map.merge(%{"recipient" => recipient, "brand" => brand})
        |> Escape.value(escape)
        |> prune(1)
        |> Map.merge(Map.new(helpers, fn {name, value} -> {name, helper(value, escape)} end))

      {:ok,
       %__MODULE__{
         channel: channel,
         escape: escape,
         locale: locale,
         tag: tag,
         time_zone: time_zone,
         isolate: direction(locale) == :rtl and channel != :sms,
         vars: vars,
         fallbacks: fallbacks
       }}
    end
  end

  defp escape_mode?(mode) do
    if mode in Escape.modes(), do: :ok, else: violation("unknown escaping mode")
  end

  defp locale(locale) do
    with {:ok, locale} <- Relay.Locale.new(locale),
         {:ok, tag} <- Relay.Templates.Cldr.language_tag(locale) do
      {:ok, locale, tag}
    else
      _ -> violation("the locale is not supported")
    end
  end

  defp time_zone(zone) do
    case Relay.TimeZone.new(zone) do
      {:ok, zone} -> {:ok, zone}
      {:error, _} -> violation("the time zone is not an IANA zone")
    end
  end

  defp plain(field, value) when is_map(value) do
    if plain?(value, 0),
      do: {:ok, value},
      else: violation("#{field} must be plain JSON data")
  end

  defp plain(field, _value), do: violation("#{field} must be a JSON object")

  defp plain?(_value, depth) when depth > 64, do: false

  defp plain?(map, depth) when is_map(map) and not is_struct(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and plain?(value, depth + 1) end)

  defp plain?(list, depth) when is_list(list), do: Enum.all?(list, &plain?(&1, depth + 1))
  defp plain?(string, _depth) when is_binary(string), do: String.valid?(string)
  defp plain?(value, _depth) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp plain?(_value, _depth), do: false

  defp helpers(helpers) when is_map(helpers) do
    if Enum.all?(helpers, &helper?/1),
      do: {:ok, helpers},
      else: violation("helpers must map names to strings")
  end

  defp helpers(_helpers), do: violation("helpers must map names to strings")

  defp helper?({name, value}) when is_binary(name) and is_binary(value),
    do: String.valid?(value)

  defp helper?({name, {:trusted, value}}) when is_binary(name) and is_binary(value),
    do: String.valid?(value)

  defp helper?(_entry), do: false

  defp helper({:trusted, value}, _escape), do: value
  defp helper(value, escape), do: Escape.escape(value, escape)

  defp reserved(data, helpers) do
    clash =
      Enum.find(Map.keys(helpers), &(&1 in @reserved)) ||
        Enum.find(@reserved ++ Map.keys(helpers), &Map.has_key?(data, &1))

    if clash, do: violation("#{clash} is a reserved name"), else: :ok
  end

  defp validate(_data, nil), do: :ok

  defp validate(data, %JSV.Root{} = root) do
    case JSV.validate(data, root, cast: false) do
      {:ok, _} -> :ok
      {:error, _} -> violation("the event data does not match the event schema")
    end
  end

  defp criticality(data, variables) do
    variables
    |> Enum.sort_by(fn {path, _declaration} -> path end)
    |> Enum.reduce({data, []}, fn {path, declaration}, {data, used} ->
      case declaration do
        %{class: :fallback, default: default} -> fill(data, path, {:fallback, default}, used)
        %{class: class} when class in [:optional, :decorative] -> fill(data, path, :null, used)
        _ -> {data, used}
      end
    end)
    |> then(fn {data, used} -> {data, Enum.reverse(used)} end)
  end

  defp fill(data, path, mode, used) do
    {data, count} = fill_segments(data, Relay.Templates.Variables.segments(path), mode)
    if count > 0, do: {data, List.duplicate(path, count) ++ used}, else: {data, used}
  end

  defp fill_segments(map, [key], mode) when is_map(map) and is_binary(key) do
    case {Map.has_key?(map, key), mode} do
      {true, _mode} -> {map, 0}
      {false, :null} -> {Map.put(map, key, nil), 0}
      {false, {:fallback, default}} -> {Map.put(map, key, default), 1}
    end
  end

  defp fill_segments(map, [key | rest], mode) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, child} ->
        {child, count} = fill_segments(child, rest, mode)
        {Map.put(map, key, child), count}

      :error ->
        {map, 0}
    end
  end

  defp fill_segments(list, [:index | rest], mode) when is_list(list) do
    {items, count} =
      Enum.map_reduce(list, 0, fn item, total ->
        {item, count} = fill_segments(item, rest, mode)
        {item, total + count}
      end)

    {items, count}
  end

  defp fill_segments(value, _segments, _mode), do: {value, 0}

  defp prune(map, depth) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, prune_value(value, depth)} end)

  defp prune_value(value, depth) when is_map(value) or is_list(value) do
    cond do
      depth >= @max_depth -> nil
      is_map(value) -> prune(value, depth + 1)
      true -> Enum.map(value, &prune_value(&1, depth + 1))
    end
  end

  defp prune_value(value, _depth), do: value

  defp violation(detail), do: {:error, {:schema_violation, detail}}
end
