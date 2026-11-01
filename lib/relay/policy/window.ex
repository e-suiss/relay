defmodule Relay.Policy.Window do
  @moduledoc """
  When a delivery may go, in the recipient's local time (PC-46, PC-58 (5)). A constraint has a name and one of three forms: `{:quiet, ranges}` blocks inside the ranges (quiet hours), `{:only, ranges}` blocks outside them (a weekly availability schedule, the 10:00–18:00 window of PC-48) and `{:until, instant}` blocks before an instant (`dnd_until`). A range is `%{days: [1..7], from: Time.t(), to: Time.t()}`: it starts on each listed ISO weekday at `from` and ends at `to`, on the next day when `to` is not after `from`, so `22:00`–`07:00` crosses midnight and `00:00`–`00:00` is the whole day.

  Ranges are wall-clock times. Every instant is mapped to the wall clock of the zone, so a local time skipped by a daylight saving gap never occurs and one repeated by an overlap occurs twice; the earliest allowed instant is the first one whose wall-clock time no constraint blocks. The search runs at minute resolution and skips whole blocked stretches, never past an allowed minute.
  """

  alias Relay.Policy.Zone

  @type range :: %{days: [1..7], from: Time.t(), to: Time.t()}
  @type form :: {:quiet, [range()]} | {:only, [range()]} | {:until, DateTime.t()}
  @type constraint :: {atom(), form()}

  @minute_ms 60_000
  @lookahead_days 8

  # PC-58 (5)
  @doc "The name of the first constraint that blocks `at`, or `nil` when none does."
  @spec blocking(DateTime.t(), Relay.TimeZone.t(), [constraint()]) :: atom() | nil
  def blocking(%DateTime{} = at, zone, constraints) do
    local = Zone.local(at, zone)

    Enum.find_value(constraints, fn {name, form} ->
      if exit_target(form, at, local) == nil, do: nil, else: name
    end)
  end

  # PC-46
  # PC-58 (5)
  @doc "The earliest instant at or after `from`, rounded up to the second, and before `limit` that no constraint blocks, or `:none`."
  @spec next_allowed(DateTime.t(), DateTime.t(), Relay.TimeZone.t(), [constraint()]) ::
          {:ok, DateTime.t()} | :none
  def next_allowed(%DateTime{} = from, %DateTime{} = limit, zone, constraints),
    do: search(ceil_second(from), limit, zone, constraints)

  # WF-42
  @doc "For an allowed `at`: how many milliseconds, at most `max_ms`, the following instants stay allowed and before `limit`."
  @spec allowed_ms(DateTime.t(), DateTime.t(), Relay.TimeZone.t(), [constraint()], integer()) ::
          non_neg_integer()
  def allowed_ms(%DateTime{} = at, %DateTime{} = limit, zone, constraints, max_ms) do
    cap = max(0, min(max_ms, DateTime.diff(limit, at, :millisecond)))
    run(at, @minute_ms, cap, zone, constraints)
  end

  defp run(_at, offset_ms, cap, _zone, _constraints) when offset_ms >= cap, do: cap

  defp run(at, offset_ms, cap, zone, constraints) do
    if blocking(DateTime.add(at, offset_ms, :millisecond), zone, constraints),
      do: offset_ms,
      else: run(at, offset_ms + @minute_ms, cap, zone, constraints)
  end

  defp search(at, limit, zone, constraints) do
    if DateTime.compare(at, limit) == :lt do
      local = Zone.local(at, zone)

      case Enum.flat_map(constraints, &candidate(&1, at, local, zone)) do
        [] -> {:ok, at}
        candidates -> search(latest(at, candidates), limit, zone, constraints)
      end
    else
      :none
    end
  end

  defp latest(at, candidates), do: Enum.max([next_minute(at) | candidates], DateTime)

  defp candidate({_name, form}, at, local, zone) do
    case exit_target(form, at, local) do
      nil -> []
      :never -> [DateTime.add(at, @lookahead_days + 1, :day)]
      %DateTime{} = instant -> [ceil_minute(instant)]
      %NaiveDateTime{} = target -> [from_wall(at, local, target, zone)]
    end
  end

  defp from_wall(at, local, target, zone) do
    guess = DateTime.add(at, NaiveDateTime.diff(target, local, :second), :second)
    shift = Zone.offset(guess, zone) - Zone.offset(at, zone)
    if shift > 0, do: DateTime.add(guess, -shift, :second), else: guess
  end

  defp exit_target({:until, until}, at, _local),
    do: if(DateTime.compare(at, until) == :lt, do: until, else: nil)

  defp exit_target({:quiet, ranges}, _at, local) do
    ends =
      for range <- ranges,
          {start, stop} <- spans(range, local),
          inside?(local, start, stop),
          do: stop

    if ends == [], do: nil, else: Enum.max(ends, NaiveDateTime)
  end

  defp exit_target({:only, ranges}, _at, local) do
    spans = for range <- ranges, span <- spans(range, local), do: span

    if Enum.any?(spans, fn {start, stop} -> inside?(local, start, stop) end) do
      nil
    else
      spans
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&(NaiveDateTime.compare(&1, local) == :gt))
      |> Enum.min(NaiveDateTime, fn -> :never end)
    end
  end

  defp spans(%{days: days, from: from, to: to}, local) do
    today = NaiveDateTime.to_date(local)

    for offset <- -1..@lookahead_days,
        date <- [Date.add(today, offset)],
        Date.day_of_week(date) in days do
      stop_date = if Time.compare(to, from) == :gt, do: date, else: Date.add(date, 1)
      {NaiveDateTime.new!(date, from), NaiveDateTime.new!(stop_date, to)}
    end
  end

  defp inside?(local, start, stop),
    do: NaiveDateTime.compare(local, start) != :lt and NaiveDateTime.compare(local, stop) == :lt

  defp next_minute(at), do: DateTime.add(floor_minute(at), 60, :second)

  defp ceil_minute(at) do
    floor = floor_minute(at)

    if DateTime.compare(floor, at) == :lt,
      do: DateTime.add(floor, 60, :second),
      else: floor
  end

  defp floor_minute(at), do: %{at | second: 0, microsecond: {0, 0}}

  defp ceil_second(at) do
    floor = %{at | microsecond: {0, 0}}

    if DateTime.compare(floor, at) == :lt,
      do: DateTime.add(floor, 1, :second),
      else: floor
  end
end
