defmodule Relay.Api.Duration do
  @moduledoc """
  ISO 8601 durations of the API (API-8) in milliseconds. Weeks, days, hours, minutes and seconds have a fixed length; a duration with years or months has no fixed length and is refused.
  """

  @pattern ~r/\AP(?!\z)(?:(\d+)W)?(?:(\d+)D)?(?:T(?=\d)(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/
  @units [604_800_000, 86_400_000, 3_600_000, 60_000, 1_000]

  # API-8
  @doc "Reads a duration as milliseconds; `:error` for years, months or anything that is not a duration."
  @spec to_ms(String.t()) :: {:ok, non_neg_integer()} | :error
  def to_ms(text) when is_binary(text) do
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

  def to_ms(_text), do: :error
end
