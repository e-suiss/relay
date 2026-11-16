defmodule Relay.Workflow.Span do
  @moduledoc """
  ISO 8601 durations of workflow step fields in milliseconds (API-8). Weeks, days, hours, minutes and seconds have a fixed length; a duration with years or months, a zero duration or anything that is not a duration is refused.
  """

  @pattern ~r/\AP(?!\z)(?:(\d+)W)?(?:(\d+)D)?(?:T(?=\d)(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/
  @units [604_800_000, 86_400_000, 3_600_000, 60_000, 1_000]

  # API-8
  @doc "Reads a positive duration as milliseconds; `:error` otherwise."
  @spec ms(term()) :: {:ok, pos_integer()} | :error
  def ms(text) when is_binary(text) do
    case Regex.run(@pattern, text) do
      [_ | parts] -> positive(total(parts))
      nil -> :error
    end
  end

  def ms(_text), do: :error

  defp total(parts) do
    parts
    |> Kernel.++(List.duplicate("", length(@units) - length(parts)))
    |> Enum.zip(@units)
    |> Enum.reduce(0, fn
      {"", _unit}, acc -> acc
      {digits, unit}, acc -> acc + String.to_integer(digits) * unit
    end)
  end

  defp positive(ms) when ms > 0, do: {:ok, ms}
  defp positive(_ms), do: :error
end
