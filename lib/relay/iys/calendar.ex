defmodule Relay.Iys.Calendar do
  @moduledoc """
  The business day calculator of the İYS write path (PC-31, PC-60). It is pure: the calendar is the content of a `business_calendar` data set version for one country, and every date is a date of Turkey time.

  A Saturday, a Sunday and a full-day public holiday are not business days; a half day (the eve of a holiday) is a business day, so a period ends earlier, on the safe side. Past the last day the calendar covers only weekends are known, so only they are left out there, which again ends a period earlier, and the result says that it went beyond the coverage so that the operator is told. `coverage/2` says how long the calendar still covers: a warning starts `warning_days/0` days before the end.

  A consent may be recorded for three business days (`consent_days/0`): `deadline/2` is the clock time of the consent on the third business day after the day it was given.
  """

  @zone "Europe/Istanbul"
  @consent_days 3
  @warning_days 60

  @enforce_keys [:holidays, :coverage_start, :coverage_end]
  defstruct [:holidays, :coverage_start, :coverage_end]

  @type t :: %__MODULE__{
          holidays: MapSet.t(Date.t()),
          coverage_start: Date.t(),
          coverage_end: Date.t()
        }
  @type reach :: :covered | :beyond_coverage

  # PC-31
  @doc "The business days a consent may wait for its İYS record."
  @spec consent_days() :: pos_integer()
  def consent_days, do: @consent_days

  # PC-60
  @doc "How many days before the end of the coverage the warning starts."
  @spec warning_days() :: pos_integer()
  def warning_days, do: @warning_days

  @doc "The time zone the İYS dates are written in."
  @spec zone() :: String.t()
  def zone, do: @zone

  # PC-60
  @doc "Reads the calendar of `country` from the content of a `business_calendar` version."
  @spec parse(map(), String.t()) :: {:ok, t()} | {:error, :country_missing | :invalid_calendar}
  def parse(%{"countries" => %{} = countries}, country) when is_binary(country) do
    case Map.fetch(countries, country) do
      {:ok, %{"holidays" => holidays, "coverage_start" => first, "coverage_end" => last}} ->
        calendar(holidays, first, last)

      _missing ->
        {:error, :country_missing}
    end
  end

  def parse(_content, _country), do: {:error, :invalid_calendar}

  defp calendar(holidays, first, last) when is_list(holidays) do
    with {:ok, first} <- date(first),
         {:ok, last} <- date(last),
         {:ok, days} <- dates(holidays) do
      {:ok, %__MODULE__{holidays: MapSet.new(days), coverage_start: first, coverage_end: last}}
    end
  end

  defp calendar(_holidays, _first, _last), do: {:error, :invalid_calendar}

  defp dates(texts) do
    Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
      case date(text) do
        {:ok, day} -> {:cont, {:ok, [day | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp date(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, day} -> {:ok, day}
      {:error, _reason} -> {:error, :invalid_calendar}
    end
  end

  defp date(_other), do: {:error, :invalid_calendar}

  # PC-60
  @doc "Whether `day` is a business day: not a weekend day and, inside the coverage, not a full-day holiday."
  @spec business_day?(t(), Date.t()) :: boolean()
  def business_day?(%__MODULE__{} = calendar, %Date{} = day) do
    Date.day_of_week(day) < 6 and not MapSet.member?(calendar.holidays, day)
  end

  # PC-60
  @doc "The day `count` business days after `day`, and whether the count stayed inside the coverage."
  @spec add_business_days(t(), Date.t(), pos_integer()) :: {Date.t(), reach()}
  def add_business_days(%__MODULE__{} = calendar, %Date{} = day, count)
      when is_integer(count) and count > 0 do
    last = step(calendar, day, count)
    {last, reach(calendar, day, last)}
  end

  defp step(_calendar, day, 0), do: day

  defp step(calendar, day, left) do
    next = Date.add(day, 1)
    left = if business_day?(calendar, next), do: left - 1, else: left
    step(calendar, next, left)
  end

  defp reach(calendar, first, last) do
    inside? =
      Date.compare(first, calendar.coverage_start) != :lt and
        Date.compare(last, calendar.coverage_end) != :gt

    if inside?, do: :covered, else: :beyond_coverage
  end

  # PC-30
  # PC-31
  # PC-60
  @doc "The instant until which a consent given at `consent_at` may be recorded in İYS: its Turkey clock time on the third business day after the day it was given."
  @spec deadline(t(), DateTime.t()) :: {DateTime.t(), reach()}
  def deadline(%__MODULE__{} = calendar, %DateTime{} = consent_at) do
    local = DateTime.shift_zone!(consent_at, @zone)
    {day, reach} = add_business_days(calendar, DateTime.to_date(local), @consent_days)
    {instant(day, DateTime.to_time(local)), reach}
  end

  defp instant(day, time) do
    local =
      case DateTime.new(day, time, @zone) do
        {:ok, at} -> at
        {:ambiguous, first, _second} -> first
        {:gap, _before, later} -> later
      end

    local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end

  # PC-60
  @doc "How long the calendar still covers on `today`: `:ok`, `{:ending, days_left}` inside the warning period, or `:ended`."
  @spec coverage(t(), Date.t()) :: :ok | {:ending, non_neg_integer()} | :ended
  def coverage(%__MODULE__{coverage_end: last}, %Date{} = today) do
    case Date.diff(last, today) do
      left when left < 0 -> :ended
      left when left <= @warning_days -> {:ending, left}
      _left -> :ok
    end
  end

  @doc "A date and time as İYS writes it: `YYYY-MM-DD HH:mm:ss` in Turkey time."
  @spec format(DateTime.t()) :: String.t()
  def format(%DateTime{} = at) do
    at |> DateTime.shift_zone!(@zone) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  @doc "Reads a date and time İYS wrote (`YYYY-MM-DD HH:mm:ss`, Turkey time) as a UTC instant; `nil` for anything else."
  @spec parse_time(term()) :: DateTime.t() | nil
  def parse_time(<<date::binary-size(10), " ", time::binary-size(8)>>) do
    with {:ok, day} <- Date.from_iso8601(date),
         {:ok, clock} <- Time.from_iso8601(time) do
      instant(day, clock)
    else
      _invalid -> nil
    end
  end

  def parse_time(_other), do: nil
end
