defmodule Relay.Workflow.Steps.TimeWindow do
  @moduledoc """
  The time window step (WF-8, WF-45, WF-47): the run goes on at once when the business time falls inside one of the step's windows on the recipient's local wall clock, and otherwise waits until the next window opens. The zone is the recipient's time zone from the WF-45 chain; local time is computed only here, in the application, with the bundled tzdata. A window start that falls into a daylight saving gap opens at the first instant after the gap, and an ambiguous one at its first occurrence.
  """

  @behaviour Relay.Workflow.Step

  @days %{1 => "mon", 2 => "tue", 3 => "wed", 4 => "thu", 5 => "fri", 6 => "sat", 7 => "sun"}

  # WF-45
  # WF-47
  @impl Relay.Workflow.Step
  def run(step, context, now) do
    zone = context.time_zone || "Etc/UTC"
    windows = step["windows"] || []
    local = DateTime.shift_zone!(now, zone)

    if Enum.any?(windows, &open?(&1, local)) do
      {:continue, %{"outcome" => "open"}}
    else
      at = next_start(windows, now, local, zone)
      {:wait_until, at, %{"outcome" => "deferred", "until" => DateTime.to_iso8601(at)}}
    end
  end

  defp open?(window, local) do
    clock = local |> DateTime.to_time() |> Time.to_string() |> binary_part(0, 5)
    day(local) in window["days"] and window["start"] <= clock and clock < window["end"]
  end

  defp day(%{} = date), do: Map.fetch!(@days, Date.day_of_week(date))

  defp next_start(windows, now, local, zone) do
    today = DateTime.to_date(local)

    starts =
      for offset <- 0..7,
          date = Date.add(today, offset),
          window <- windows,
          day(date) in window["days"],
          at = instant(date, window["start"], zone),
          DateTime.compare(at, now) == :gt,
          do: at

    Enum.min(starts, DateTime, fn -> DateTime.add(now, 86_400, :second) end)
  end

  defp instant(date, start, zone) do
    [hour, minute] = start |> String.split(":") |> Enum.map(&String.to_integer/1)
    naive = NaiveDateTime.new!(date, Time.new!(hour, minute, 0))

    case DateTime.from_naive(naive, zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
    end
  end
end
