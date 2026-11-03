defmodule Relay.Templates.Channel.Whatsapp do
  @moduledoc """
  The WhatsApp parameter cleaner (TP-23, TP-15). It runs after render and before sending, on every parameter of the approved Meta template: invalid UTF-8 is removed, line breaks and tabs become a space, a run of four or more spaces becomes three, and a value over its component limit is cut at a grapheme boundary. Every change is recorded (INV-1).

  Component limits (the "1024/60/60/25" of TP-15), counted in graphemes: `:body` 1024, `:header` 60, `:footer` 60, `:button` 25. A parameter is limited by the limit of the component it is placed in; the limit applies to each value.
  """

  alias Relay.Templates.Sanitizer

  @type component :: :body | :header | :footer | :button
  @type parameter :: {component(), binary()}

  @limits %{body: 1024, header: 60, footer: 60, button: 25}

  # TP-15
  # TP-23
  @doc "The grapheme limit of a component."
  @spec limit(component()) :: pos_integer()
  def limit(component), do: Map.fetch!(@limits, component)

  # TP-23
  @doc "Cleans one parameter value placed in `component`; `field` names it in the change log."
  @spec clean(binary(), component(), String.t() | nil) :: Sanitizer.result()
  def clean(value, component, field \\ nil) when is_map_key(@limits, component) do
    Sanitizer.pipe(value, [
      &Sanitizer.utf8(&1, field),
      &replace(&1, ~r/\r\n|[\r\n\t]/, :line_break, field),
      &replace(&1, ~r/ {4,}/, :space_run, field),
      &truncate(&1, limit(component), field)
    ])
  end

  # TP-23
  @doc "Cleans parameters in order; each change names its parameter as `component/index` with a 1-based index within the component."
  @spec clean_all([parameter()]) :: {[String.t()], [Sanitizer.change()]}
  def clean_all(parameters) do
    {values, {changes, _counters}} =
      Enum.map_reduce(parameters, {[], %{}}, fn {component, value}, {changes, counters} ->
        index = Map.get(counters, component, 0) + 1
        {clean, more} = clean(value, component, "#{component}/#{index}")
        {clean, {changes ++ more, Map.put(counters, component, index)}}
      end)

    {values, changes}
  end

  defp replace(value, pattern, rule, field) do
    case length(Regex.scan(pattern, value)) do
      0 ->
        {value, []}

      count ->
        replacement = if rule == :space_run, do: "   ", else: " "
        change = Sanitizer.change(rule, :replaced, count, field: field)
        {String.replace(value, pattern, replacement), [change]}
    end
  end

  defp truncate(value, limit, field) do
    length = String.length(value)

    if length > limit do
      detail = %{graphemes: length, limit: limit}
      cut = length - limit
      change = Sanitizer.change(:truncated, :truncated, cut, field: field, detail: detail)
      {String.slice(value, 0, limit), [change]}
    else
      {value, []}
    end
  end
end
