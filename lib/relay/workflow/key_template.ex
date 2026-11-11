defmodule Relay.Workflow.KeyTemplate do
  @moduledoc """
  Renders the template strings of a step's grouping and counting keys (`digest_key`, `throttle_key`, WF-26, WF-32): every `{{path}}` placeholder is replaced with the value at `data.…` (the event data) or `recipient.<attribute>` (a declared recipient attribute) as text; a missing value renders as the empty string. Nothing else is evaluated.
  """

  @placeholder ~r/\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}/

  # WF-26
  # WF-32
  @doc "Renders a key template against a run context's `data` and `recipient`."
  @spec render(String.t() | nil, map()) :: String.t()
  def render(nil, _context), do: ""

  def render(template, context) when is_binary(template) do
    Regex.replace(@placeholder, template, fn _match, path ->
      path |> String.split(".") |> value(context) |> text()
    end)
  end

  defp value(["data" | rest], context), do: dig(Map.get(context, :data), rest)
  defp value(["recipient" | rest], context), do: dig(Map.get(context, :recipient), rest)
  defp value(_path, _context), do: nil

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: dig(Map.get(map, key), rest)

  defp dig(list, [index | rest]) when is_list(list) do
    case Integer.parse(index) do
      {n, ""} when n >= 0 -> dig(Enum.at(list, n), rest)
      _other -> nil
    end
  end

  defp dig(_value, _rest), do: nil

  defp text(value) when is_binary(value), do: value

  defp text(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp text(_value), do: ""
end
