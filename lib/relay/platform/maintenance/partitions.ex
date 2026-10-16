defmodule Relay.Platform.Maintenance.Partitions do
  @moduledoc """
  Pure partition planning. Bounds are UTC midnights (daily) or UTC first-of-month midnights (monthly). Given a table's policy and its furthest bound, `plan/3` lists the `[from, to)` ranges that bring the furthest bound to at least `now + premake horizon`; `alarm?/3` tells whether the furthest bound is closer than the alarm threshold.
  """

  @type interval :: :day | :month
  @type range :: {DateTime.t(), DateTime.t()}

  # OP-13
  @doc "Truncates a time to the start of its UTC day or month."
  @spec period_start(DateTime.t(), interval()) :: DateTime.t()
  def period_start(%DateTime{} = at, :day), do: midnight(DateTime.to_date(utc(at)))

  def period_start(%DateTime{} = at, :month) do
    date = DateTime.to_date(utc(at))
    midnight(Date.new!(date.year, date.month, 1))
  end

  @doc "Returns the next bound after a bound."
  @spec next(DateTime.t(), interval()) :: DateTime.t()
  def next(%DateTime{} = bound, :day), do: midnight(Date.add(DateTime.to_date(bound), 1))

  def next(%DateTime{} = bound, :month),
    do: midnight(Date.shift(DateTime.to_date(bound), month: 1))

  @doc "Shifts a time by a PostgreSQL interval (months, then days, then seconds), in UTC."
  @spec shift(DateTime.t(), Postgrex.Interval.t()) :: DateTime.t()
  def shift(%DateTime{} = at, %Postgrex.Interval{} = interval) do
    at
    |> utc()
    |> DateTime.shift(month: interval.months, day: interval.days)
    |> DateTime.add(interval.secs * 1_000_000 + interval.microsecs, :microsecond)
  end

  # OP-13
  # OP-14
  # OP-66
  @doc "Lists the partitions to create so that the furthest bound reaches `now + premake`; with no partition yet the first one starts at the current period."
  @spec plan(
          %{interval: interval(), premake: Postgrex.Interval.t()},
          DateTime.t() | nil,
          DateTime.t()
        ) ::
          [range()]
  def plan(%{interval: interval, premake: premake}, furthest, %DateTime{} = now) do
    target = shift(now, premake)
    start = if furthest, do: utc(furthest), else: period_start(now, interval)
    ranges(start, target, interval, [])
  end

  defp ranges(from, target, interval, acc) do
    if DateTime.compare(from, target) == :lt do
      to = next(from, interval)
      ranges(to, target, interval, [{from, to} | acc])
    else
      Enum.reverse(acc)
    end
  end

  @doc "Returns true if the furthest bound is missing or earlier than `now + threshold`."
  @spec alarm?(DateTime.t() | nil, Postgrex.Interval.t(), DateTime.t()) :: boolean()
  def alarm?(nil, _threshold, _now), do: true

  def alarm?(%DateTime{} = furthest, %Postgrex.Interval{} = threshold, %DateTime{} = now),
    do: DateTime.compare(utc(furthest), shift(now, threshold)) == :lt

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")

  defp utc(%DateTime{} = at) do
    utc = DateTime.shift_zone!(at, "Etc/UTC")
    {us, _precision} = utc.microsecond
    %{utc | microsecond: {us, 6}}
  end
end
