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

  # API-8
  @doc "Reads a duration as a database interval of seconds; `:error` as `to_ms/1`."
  @spec to_interval(String.t()) :: {:ok, Postgrex.Interval.t()} | :error
  def to_interval(text) do
    case to_ms(text) do
      {:ok, ms} -> {:ok, %Postgrex.Interval{months: 0, days: 0, secs: div(ms, 1_000)}}
      :error -> :error
    end
  end

  # API-8
  @doc "Writes a database interval without months as an ISO 8601 duration of days, hours, minutes and seconds; `nil` stays `nil`."
  @spec iso(Postgrex.Interval.t() | nil) :: String.t() | nil
  def iso(nil), do: nil

  def iso(%Postgrex.Interval{days: days, secs: secs}) do
    total = days * 86_400 + secs
    {d, rest} = {div(total, 86_400), rem(total, 86_400)}
    {h, m, s} = {div(rest, 3_600), div(rem(rest, 3_600), 60), rem(rest, 60)}
    date = if d > 0, do: "#{d}D", else: ""
    time = part(h, "H") <> part(m, "M") <> part(s, "S")

    cond do
      time != "" -> "P" <> date <> "T" <> time
      date != "" -> "P" <> date
      true -> "PT0S"
    end
  end

  defp part(0, _unit), do: ""
  defp part(n, unit), do: Integer.to_string(n) <> unit
end
