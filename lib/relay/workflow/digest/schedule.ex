defmodule Relay.Workflow.Digest.Schedule do
  @moduledoc """
  The calendar of a `scheduled` digest window (WF-26, WF-59): the `DAILY` and `WEEKLY` part of the RRULE subset (WF-61), read in the recipient's time zone (WF-45). A rule is `FREQ=DAILY` or `FREQ=WEEKLY` with one `BYHOUR` (0–23), at most one `BYMINUTE` (0–59, default 0), for `WEEKLY` a `BYDAY` list of weekday codes without ordinals (default every day), and `INTERVAL` only as 1, because a window rule carries no `DTSTART` to count intervals from. Any other part is refused.

  The next occurrence is the first wall-clock time of the rule strictly after an instant; a time skipped by a daylight saving gap falls on the first instant after the gap and a repeated time on its first occurrence. Time zone arithmetic happens here only, never in SQL (WF-47).
  """

  @days %{"MO" => 1, "TU" => 2, "WE" => 3, "TH" => 4, "FR" => 5, "SA" => 6, "SU" => 7}
  @horizon_days 8

  @type t :: %{freq: :daily | :weekly, days: [1..7], hour: 0..23, minute: 0..59}

  # WF-26
  # WF-61
  @doc "Parses a rule of the subset; `:error` for any part outside it."
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(text) when is_binary(text) and byte_size(text) <= 256 do
    with {:ok, parts} <- parts(text),
         {:ok, freq} <- freq(parts),
         :ok <- interval(parts),
         {:ok, days} <- days(freq, parts),
         {:ok, hour} <- number(parts, "BYHOUR", 0..23, :required),
         {:ok, minute} <- number(parts, "BYMINUTE", 0..59, 0) do
      {:ok, %{freq: freq, days: days, hour: hour, minute: minute}}
    end
  end

  def parse(_text), do: :error

  # WF-26
  # WF-45
  @doc "The first occurrence of the rule strictly after `from`, in the time zone `zone`."
  @spec next(t(), DateTime.t(), String.t()) :: DateTime.t()
  def next(%{days: days, hour: hour, minute: minute}, %DateTime{} = from, zone) do
    local = from |> DateTime.shift_zone!(zone) |> DateTime.to_date()

    0..@horizon_days
    |> Enum.map(&Date.add(local, &1))
    |> Enum.filter(&(Date.day_of_week(&1) in days))
    |> Enum.map(&instant(NaiveDateTime.new!(&1, Time.new!(hour, minute, 0)), zone))
    |> Enum.find(&(DateTime.compare(&1, from) == :gt))
  end

  defp instant(naive, zone) do
    case DateTime.from_naive(naive, zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, later} -> DateTime.shift_zone!(later, "Etc/UTC")
    end
  end

  defp parts(text) do
    pairs = text |> String.split(";") |> Enum.map(&pair/1)
    keys = for {key, _value} <- pairs, do: key

    cond do
      :error in pairs -> :error
      length(keys) != length(Enum.uniq(keys)) -> :error
      Enum.any?(keys, &(&1 not in ~w(FREQ INTERVAL BYDAY BYHOUR BYMINUTE))) -> :error
      true -> {:ok, Map.new(pairs)}
    end
  end

  defp pair(part) do
    case String.split(part, "=", parts: 2) do
      [key, value] when key != "" and value != "" -> {key, value}
      _malformed -> :error
    end
  end

  defp freq(%{"FREQ" => "DAILY"}), do: {:ok, :daily}
  defp freq(%{"FREQ" => "WEEKLY"}), do: {:ok, :weekly}
  defp freq(_parts), do: :error

  defp interval(%{"INTERVAL" => "1"}), do: :ok
  defp interval(%{"INTERVAL" => _other}), do: :error
  defp interval(_parts), do: :ok

  defp days(:daily, %{"BYDAY" => _days}), do: :error
  defp days(:daily, _parts), do: {:ok, Enum.to_list(1..7)}

  defp days(:weekly, %{"BYDAY" => text}) do
    codes = String.split(text, ",")
    days = Enum.map(codes, &Map.get(@days, &1))

    if nil in days or length(days) != length(Enum.uniq(days)),
      do: :error,
      else: {:ok, Enum.sort(days)}
  end

  defp days(:weekly, _parts), do: {:ok, Enum.to_list(1..7)}

  defp number(parts, key, range, default) do
    case Map.fetch(parts, key) do
      {:ok, text} -> in_range(Integer.parse(text), range)
      :error when default == :required -> :error
      :error -> {:ok, default}
    end
  end

  defp in_range({value, ""}, range), do: if(value in range, do: {:ok, value}, else: :error)
  defp in_range(_parsed, _range), do: :error
end
