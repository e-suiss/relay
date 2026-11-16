defmodule Relay.Workflow.Duration do
  @moduledoc """
  ISO 8601 durations of a workflow definition in seconds: weeks, days, hours, minutes and seconds have a fixed length; a duration with years or months has none and is refused (WF-37, WF-59).
  """

  @pattern ~r/\AP(?!\z)(?:(\d+)W)?(?:(\d+)D)?(?:T(?=\d)(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/
  @units [604_800, 86_400, 3_600, 60, 1]

  @doc "Reads a duration as seconds; `:error` for anything that is not a fixed-length duration."
  @spec seconds(term()) :: {:ok, non_neg_integer()} | :error
  def seconds(text) when is_binary(text) do
    case Regex.run(@pattern, text) do
      [_ | parts] ->
        parts = parts ++ List.duplicate("", length(@units) - length(parts))

        {:ok,
         parts
         |> Enum.zip(@units)
         |> Enum.reduce(0, fn
           {"", _unit}, acc -> acc
           {digits, unit}, acc -> acc + String.to_integer(digits) * unit
         end)}

      nil ->
        :error
    end
  end

  def seconds(_text), do: :error
end
