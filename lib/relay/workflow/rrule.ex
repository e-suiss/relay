defmodule Relay.Workflow.RRule do
  @moduledoc """
  The RRULE subset of recurring notifications (WF-61, RFC 5545 §3.3.10), parsed and expanded as a pure function of the rule, its start, its zone and a reference instant.

  Supported parts: `FREQ=DAILY|WEEKLY|MONTHLY`; `INTERVAL` 1–99 (default 1); `BYDAY` with `WEEKLY` as a list of days (`MO,WE`) and with `MONTHLY` as one day with an ordinal 1–4 or -1 (`2TU`, `-1FR`); `BYMONTHDAY` with `MONTHLY` as one value 1–28 or -1 (the last day of the month); `BYHOUR` and `BYMINUTE` as one value each; `COUNT` 1–1000 or `UNTIL` as a UTC time (`20311231T000000Z`), never both. Every other part (`SECONDLY`, `MINUTELY`, `HOURLY`, `YEARLY`, `BYSETPOS`, `BYWEEKNO`, `BYYEARDAY`, `BYMONTH`, `BYSECOND`, `WKST`, several hours or minutes, `EXDATE`, `RDATE`) is a field error that names the part. A leading `RRULE:` is accepted; the canonical text has the parts in the order above and leaves `INTERVAL=1` out.

  `DTSTART` is a local wall-clock time without an offset; the rule runs in an IANA zone with the tzdata bundled with the image, never in the database (WF-47). An occurrence is a local candidate of the rule at or after `DTSTART`: the day of each period (every `INTERVAL` days, ISO weeks starting on Monday, or months, counted from the period of `DTSTART`), at `BYHOUR`/`BYMINUTE`, else at the hour and minute of `DTSTART`, with the second of `DTSTART`. `DTSTART` is the first occurrence only when it matches the rule. A month without the day of `DTSTART` (the 30th in February) has no occurrence. `COUNT` counts occurrences from the first one; `UNTIL` is inclusive. Time zone transitions:

  * a local time that does not exist (it falls in a forward transition gap, such as 02:30 on the last Sunday of March in Europe/Berlin) moves forward to the first valid instant after the gap (03:00 local);
  * a local time that exists twice (it falls in a backward transition overlap) is its first occurrence, the one with the earlier UTC instant.
  """

  @enforce_keys [:freq]
  defstruct freq: nil,
            interval: 1,
            by_day: nil,
            by_month_day: nil,
            by_hour: nil,
            by_minute: nil,
            count: nil,
            until: nil

  @type freq :: :daily | :weekly | :monthly
  @type weekday :: 1..7
  @type t :: %__MODULE__{
          freq: freq(),
          interval: 1..99,
          by_day: [weekday()] | {-1 | 1..4, weekday()} | nil,
          by_month_day: -1 | 1..28 | nil,
          by_hour: 0..23 | nil,
          by_minute: 0..59 | nil,
          count: 1..1000 | nil,
          until: DateTime.t() | nil
        }
  @type occurrence :: %{at: DateTime.t(), local: NaiveDateTime.t(), ordinal: pos_integer() | nil}
  @type field_error :: %{pointer: String.t(), code: String.t(), detail: String.t()}

  @days ~w(MO TU WE TH FR SA SU)
  @day_numbers @days |> Enum.with_index(1) |> Map.new()
  @day_names Map.new(@day_numbers, fn {name, number} -> {number, name} end)
  @freqs %{"DAILY" => :daily, "WEEKLY" => :weekly, "MONTHLY" => :monthly}
  @unsupported_freqs ~w(SECONDLY MINUTELY HOURLY YEARLY)
  @supported ~w(FREQ INTERVAL BYDAY BYMONTHDAY BYHOUR BYMINUTE COUNT UNTIL)
  @unsupported ~w(BYSECOND BYWEEKNO BYYEARDAY BYMONTH BYSETPOS WKST EXDATE RDATE EXRULE DTSTART)
  @max_interval Relay.Limits.fetch!(["recurrence", "max_interval"])
  @max_count Relay.Limits.fetch!(["recurrence", "max_count"])
  @max_text 512
  @max_steps 100_000
  @until ~r/\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z\z/
  @integer ~r/\A[+-]?\d{1,4}\z/
  @monthly_day ~r/\A([+-]?\d)?(MO|TU|WE|TH|FR|SA|SU)\z/

  # WF-61
  # WF-48
  @doc "Parses rule text into a rule; every unsupported or malformed part is a field error under `pointer` that names the part."
  @spec parse(term(), String.t()) :: {:ok, t()} | {:error, [field_error()]}
  def parse(text, pointer \\ "/rrule")

  def parse(text, pointer) when is_binary(text) and byte_size(text) <= @max_text do
    body = String.replace_prefix(text, "RRULE:", "")

    with {:ok, parts} <- split(body, pointer) do
      build(parts, pointer)
    end
  end

  def parse(_text, pointer),
    do: {:error, [error(pointer, "invalid_format", "a rule is text of at most 512 bytes")]}

  # WF-61
  @doc "The canonical text of a rule."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = rule) do
    [
      {"FREQ", rule.freq |> Atom.to_string() |> String.upcase()},
      {"INTERVAL", if(rule.interval == 1, do: nil, else: int(rule.interval))},
      {"BYDAY", by_day_text(rule.by_day)},
      {"BYMONTHDAY", int(rule.by_month_day)},
      {"BYHOUR", int(rule.by_hour)},
      {"BYMINUTE", int(rule.by_minute)},
      {"COUNT", int(rule.count)},
      {"UNTIL", until_text(rule.until)}
    ]
    |> Enum.reject(fn {_name, value} -> value == nil end)
    |> Enum.map_join(";", fn {name, value} -> name <> "=" <> value end)
  end

  defp int(nil), do: nil
  defp int(n), do: Integer.to_string(n)

  defp until_text(nil), do: nil
  defp until_text(until), do: Calendar.strftime(until, "%Y%m%dT%H%M%SZ")

  # WF-61
  @doc "Returns field errors when `UNTIL` lies more than `max_years` calendar years after `now`."
  @spec check_horizon(t(), DateTime.t(), pos_integer(), String.t()) ::
          :ok | {:error, [field_error()]}
  def check_horizon(rule, now, max_years, pointer \\ "/rrule")

  def check_horizon(%__MODULE__{until: nil}, _now, _max_years, _pointer), do: :ok

  def check_horizon(%__MODULE__{until: until}, %DateTime{} = now, max_years, pointer) do
    horizon = DateTime.shift(now, year: max_years)

    if DateTime.compare(until, horizon) == :gt,
      do:
        {:error, [error(pointer, "not_allowed", "UNTIL lies more than #{max_years} years ahead")]},
      else: :ok
  end

  # WF-61
  # WF-47
  @doc "The first occurrence strictly after the UTC instant `from`, or `:none` when the rule has no more."
  @spec next(t(), NaiveDateTime.t(), String.t(), DateTime.t()) :: {:ok, occurrence()} | :none
  def next(%__MODULE__{} = rule, %NaiveDateTime{} = dtstart, zone, %DateTime{} = from) do
    case between(rule, dtstart, zone, from, nil, 1) do
      [occurrence] -> {:ok, occurrence}
      [] -> :none
    end
  end

  # WF-61
  # WF-47
  @doc "At most `limit` occurrences strictly after `from` and, when `upto` is given, at or before `upto`, in order."
  @spec between(
          t(),
          NaiveDateTime.t(),
          String.t(),
          DateTime.t(),
          DateTime.t() | nil,
          pos_integer()
        ) :: [occurrence()]
  def between(%__MODULE__{} = rule, %NaiveDateTime{} = dtstart, zone, from, upto, limit)
      when is_integer(limit) and limit > 0 do
    start = first_period(rule, dtstart, zone, from)

    rule
    |> stream(dtstart, zone, start)
    |> Stream.drop_while(&(DateTime.compare(&1.at, from) != :gt))
    |> Stream.take_while(&(upto == nil or DateTime.compare(&1.at, upto) != :gt))
    |> Enum.take(limit)
  end

  # WF-61
  @doc "All occurrences of a rule from its start, at most `limit`, for golden vectors and previews."
  @spec occurrences(t(), NaiveDateTime.t(), String.t(), pos_integer()) :: [occurrence()]
  def occurrences(%__MODULE__{} = rule, %NaiveDateTime{} = dtstart, zone, limit)
      when is_integer(limit) and limit > 0,
      do: rule |> stream(dtstart, zone, 0) |> Enum.take(limit)

  defp split(body, pointer) do
    parts = if body == "", do: [], else: String.split(body, ";")

    Enum.reduce_while(parts, {:ok, %{}}, fn part, {:ok, acc} ->
      case put_part(acc, String.split(part, "=", parts: 2), pointer) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, errors} -> {:halt, {:error, errors}}
      end
    end)
  end

  defp put_part(acc, [name, value], pointer) when name != "" and value != "" do
    name = String.upcase(name)

    if Map.has_key?(acc, name),
      do: {:error, [error(pointer, "invalid_format", "#{name} appears twice")]},
      else: {:ok, Map.put(acc, name, String.upcase(value))}
  end

  defp put_part(_acc, _malformed, pointer),
    do: {:error, [error(pointer, "invalid_format", "a part is not NAME=VALUE")]}

  defp build(parts, pointer) do
    errors = name_errors(parts, pointer)
    {freq, freq_errors} = freq(parts["FREQ"], pointer)
    {fields, field_errors} = fields(parts, freq, pointer)
    all = errors ++ freq_errors ++ field_errors ++ combination_errors(parts, pointer)

    if all == [],
      do: {:ok, struct!(__MODULE__, Map.put(fields, :freq, freq))},
      else: {:error, Enum.uniq(all)}
  end

  defp name_errors(parts, pointer) do
    for name <- parts |> Map.keys() |> Enum.sort(), name not in @supported do
      if name in @unsupported,
        do: error(pointer, "unsupported_value", "#{name} is not supported"),
        else: error(pointer, "unsupported_value", "#{name} is not an RRULE part Relay supports")
    end
  end

  defp freq(nil, pointer), do: {nil, [error(pointer, "required", "FREQ is required")]}

  defp freq(value, pointer) do
    cond do
      Map.has_key?(@freqs, value) -> {Map.fetch!(@freqs, value), []}
      value in @unsupported_freqs -> {nil, [unsupported(pointer, "FREQ=#{value}")]}
      true -> {nil, [error(pointer, "invalid_format", "FREQ is not a frequency")]}
    end
  end

  defp fields(parts, freq, pointer) do
    [
      {:interval, &interval/3},
      {:by_day, &by_day/3},
      {:by_month_day, &by_month_day/3},
      {:by_hour, &by_hour/3},
      {:by_minute, &by_minute/3},
      {:count, &count/3},
      {:until, &until/3}
    ]
    |> Enum.reduce({%{}, []}, fn {field, check}, {acc, errors} ->
      case check.(parts, freq, pointer) do
        {:ok, nil} -> {acc, errors}
        {:ok, value} -> {Map.put(acc, field, value), errors}
        {:error, error} -> {acc, [error | errors]}
      end
    end)
    |> then(fn {acc, errors} -> {acc, Enum.reverse(errors)} end)
  end

  defp interval(%{"INTERVAL" => text}, _freq, pointer),
    do: bounded(text, 1, @max_interval, pointer, "INTERVAL")

  defp interval(_parts, _freq, _pointer), do: {:ok, nil}

  defp by_day(%{"BYDAY" => text}, :weekly, pointer) do
    names = String.split(text, ",")

    cond do
      not Enum.all?(names, &Map.has_key?(@day_numbers, &1)) ->
        {:error, error(pointer, "invalid_format", "BYDAY with WEEKLY is a list of days")}

      length(names) != length(Enum.uniq(names)) ->
        {:error, error(pointer, "invalid_format", "BYDAY names a day twice")}

      true ->
        {:ok, names |> Enum.map(&Map.fetch!(@day_numbers, &1)) |> Enum.sort()}
    end
  end

  defp by_day(%{"BYDAY" => text}, :monthly, pointer) do
    case Regex.run(@monthly_day, text) do
      [_, ordinal, day] when ordinal != "" ->
        monthly_day(ordinal, day, pointer)

      _other ->
        {:error, unsupported(pointer, "BYDAY with MONTHLY other than one day with 1-4 or -1")}
    end
  end

  defp by_day(%{"BYDAY" => _text}, :daily, pointer),
    do: {:error, unsupported(pointer, "BYDAY with DAILY")}

  defp by_day(_parts, _freq, _pointer), do: {:ok, nil}

  defp monthly_day(ordinal, day, pointer) do
    case Integer.parse(ordinal) do
      {n, ""} when n in [-1, 1, 2, 3, 4] -> {:ok, {n, Map.fetch!(@day_numbers, day)}}
      _other -> {:error, unsupported(pointer, "BYDAY ordinal #{ordinal}")}
    end
  end

  defp by_month_day(%{"BYMONTHDAY" => text}, :monthly, pointer) do
    case integer(text) do
      {:ok, n} when n == -1 or (n >= 1 and n <= 28) -> {:ok, n}
      {:ok, _n} -> {:error, unsupported(pointer, "BYMONTHDAY=#{text}")}
      :error -> {:error, unsupported(pointer, "BYMONTHDAY other than one value 1-28 or -1")}
    end
  end

  defp by_month_day(%{"BYMONTHDAY" => _text}, _freq, pointer),
    do: {:error, unsupported(pointer, "BYMONTHDAY without MONTHLY")}

  defp by_month_day(_parts, _freq, _pointer), do: {:ok, nil}

  defp by_hour(%{"BYHOUR" => text}, _freq, pointer), do: single(text, 0, 23, pointer, "BYHOUR")
  defp by_hour(_parts, _freq, _pointer), do: {:ok, nil}

  defp by_minute(%{"BYMINUTE" => text}, _freq, pointer),
    do: single(text, 0, 59, pointer, "BYMINUTE")

  defp by_minute(_parts, _freq, _pointer), do: {:ok, nil}

  defp count(%{"COUNT" => text}, _freq, pointer),
    do: bounded(text, 1, @max_count, pointer, "COUNT")

  defp count(_parts, _freq, _pointer), do: {:ok, nil}

  defp until(%{"UNTIL" => text}, _freq, pointer) do
    with [_ | fields] <- Regex.run(@until, text),
         [year, month, day, hour, minute, second] = Enum.map(fields, &String.to_integer/1),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second) do
      {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
    else
      _ ->
        {:error, error(pointer, "invalid_format", "UNTIL is a UTC time such as 20311231T000000Z")}
    end
  end

  defp until(_parts, _freq, _pointer), do: {:ok, nil}

  defp combination_errors(parts, pointer) do
    both = fn a, b -> Map.has_key?(parts, a) and Map.has_key?(parts, b) end

    [
      both.("COUNT", "UNTIL") &&
        error(pointer, "not_allowed", "COUNT and UNTIL cannot both be given"),
      both.("BYDAY", "BYMONTHDAY") &&
        error(pointer, "not_allowed", "BYDAY and BYMONTHDAY cannot both be given")
    ]
    |> Enum.filter(& &1)
  end

  defp single(text, min, max, pointer, name) do
    if String.contains?(text, ","),
      do: {:error, unsupported(pointer, "#{name} with more than one value")},
      else: bounded(text, min, max, pointer, name)
  end

  defp bounded(text, min, max, pointer, name) do
    case integer(text) do
      {:ok, n} when n >= min and n <= max -> {:ok, n}
      _other -> {:error, error(pointer, "invalid_format", "#{name} is an integer #{min}-#{max}")}
    end
  end

  defp integer(text) do
    with true <- Regex.match?(@integer, text),
         {n, ""} <- Integer.parse(text) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp by_day_text(nil), do: nil

  defp by_day_text(days) when is_list(days),
    do: Enum.map_join(days, ",", &Map.fetch!(@day_names, &1))

  defp by_day_text({n, day}), do: Integer.to_string(n) <> Map.fetch!(@day_names, day)

  defp unsupported(pointer, part),
    do: error(pointer, "unsupported_value", "#{part} is not supported")

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}

  defp stream(rule, dtstart, zone, start) do
    start
    |> Stream.iterate(&(&1 + 1))
    |> Stream.take(@max_steps)
    |> Stream.flat_map(&candidates(rule, dtstart, &1))
    |> Stream.filter(&(NaiveDateTime.compare(&1, dtstart) != :lt))
    |> Stream.map(&%{at: instant(&1, zone), local: &1})
    |> Stream.take_while(&(rule.until == nil or DateTime.compare(&1.at, rule.until) != :gt))
    |> number(rule, start)
  end

  defp number(stream, %__MODULE__{count: nil}, _start),
    do: Stream.map(stream, &Map.put(&1, :ordinal, nil))

  defp number(stream, %__MODULE__{count: count}, 0) do
    stream
    |> Stream.with_index(1)
    |> Stream.map(fn {occurrence, n} -> Map.put(occurrence, :ordinal, n) end)
    |> Stream.take(count)
  end

  defp first_period(%__MODULE__{count: count}, _dtstart, _zone, _from) when count != nil, do: 0

  defp first_period(rule, dtstart, zone, from) do
    local = from |> DateTime.shift_zone!(zone) |> DateTime.to_naive() |> NaiveDateTime.to_date()
    max(periods_between(rule, NaiveDateTime.to_date(dtstart), local) - 1, 0)
  end

  defp periods_between(%__MODULE__{freq: :daily, interval: n}, from, to),
    do: floor_div(Date.diff(to, from), n)

  defp periods_between(%__MODULE__{freq: :weekly, interval: n}, from, to),
    do: floor_div(floor_div(Date.diff(monday(to), monday(from)), 7), n)

  defp periods_between(%__MODULE__{freq: :monthly, interval: n}, from, to),
    do: floor_div(to.year * 12 + to.month - (from.year * 12 + from.month), n)

  defp floor_div(a, b), do: Integer.floor_div(a, b)

  defp candidates(%__MODULE__{freq: :daily} = rule, dtstart, period) do
    date = Date.add(NaiveDateTime.to_date(dtstart), period * rule.interval)
    [at(date, rule, dtstart)]
  end

  defp candidates(%__MODULE__{freq: :weekly} = rule, dtstart, period) do
    start = Date.add(monday(NaiveDateTime.to_date(dtstart)), 7 * period * rule.interval)
    days = rule.by_day || [Date.day_of_week(dtstart)]
    for day <- days, do: at(Date.add(start, day - 1), rule, dtstart)
  end

  defp candidates(%__MODULE__{freq: :monthly} = rule, dtstart, period) do
    months = dtstart.year * 12 + dtstart.month - 1 + period * rule.interval
    {year, month} = {div(months, 12), rem(months, 12) + 1}

    case month_day(rule, dtstart, year, month) do
      nil -> []
      day -> [at(Date.new!(year, month, day), rule, dtstart)]
    end
  end

  defp month_day(%__MODULE__{by_month_day: -1}, _dtstart, year, month),
    do: :calendar.last_day_of_the_month(year, month)

  defp month_day(%__MODULE__{by_month_day: day}, _dtstart, _year, _month) when is_integer(day),
    do: day

  defp month_day(%__MODULE__{by_day: {-1, weekday}}, _dtstart, year, month) do
    last = Date.new!(year, month, :calendar.last_day_of_the_month(year, month))
    last.day - Integer.mod(Date.day_of_week(last) - weekday, 7)
  end

  defp month_day(%__MODULE__{by_day: {n, weekday}}, _dtstart, year, month) do
    first = Date.new!(year, month, 1)
    1 + Integer.mod(weekday - Date.day_of_week(first), 7) + 7 * (n - 1)
  end

  defp month_day(_rule, dtstart, year, month) do
    if dtstart.day <= :calendar.last_day_of_the_month(year, month), do: dtstart.day, else: nil
  end

  defp at(date, rule, dtstart) do
    time =
      Time.new!(rule.by_hour || dtstart.hour, rule.by_minute || dtstart.minute, dtstart.second)

    NaiveDateTime.new!(date, time)
  end

  defp monday(date), do: Date.add(date, 1 - Date.day_of_week(date))

  defp instant(local, zone) do
    case DateTime.from_naive(local, zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, just_after} -> DateTime.shift_zone!(just_after, "Etc/UTC")
    end
  end
end
