defmodule Relay.Workflow.Throttle.Window do
  @moduledoc """
  The pure core of a throttle step (WF-32, WF-37). `config/2` reads the step fields: `key` (the tenant-wide key, a template string the run renders), `limit` (1–10000 events per window) and exactly one window: `window` (an ISO 8601 duration from the first counted event, at most P31D), `until` (a pointer to an RFC 3339 time in the event data, resolved by the run) or `calendar` (`day` or `week`, the recipient's calendar day or ISO week in their time zone, WF-45). `bounds/3` turns a configuration into the window the counter opens when none is active: anchored at the first event for `window` and `until`, the local calendar day or week otherwise. Time zone arithmetic happens here only, never in SQL (WF-47).
  """

  alias Relay.Workflow.Span

  @max_ms Relay.Limits.seconds!(["throttle", "max_window"]) * 1_000
  @limit Relay.Limits.fetch!(["throttle", "limit"])
  @key_bytes Relay.Limits.fetch!(["throttle", "max_key_bytes"])

  @type window :: {:window, pos_integer()} | {:until, String.t()} | {:calendar, :day | :week}
  @type t :: %{key: String.t(), limit: pos_integer(), window: window()}
  @type bounds ::
          {:anchored, pos_integer()}
          | {:until, DateTime.t()}
          | {:span, DateTime.t(), DateTime.t()}
  @type field_error :: %{pointer: String.t(), code: String.t(), detail: String.t()}

  # WF-32
  # WF-59
  @doc "Reads the fields of a `throttle` step, or returns its field errors under `pointer`."
  @spec config(map(), String.t()) :: {:ok, t()} | {:error, [field_error(), ...]}
  def config(step, pointer \\ "") when is_map(step) do
    checks = [key: key(step["key"]), limit: limit(step["limit"]), window: window(step)]

    errors =
      for {name, {:error, code, detail}} <- checks,
          do: %{pointer: "#{pointer}/#{name}", code: code, detail: detail}

    case errors do
      [] -> {:ok, Map.new(checks, fn {name, {:ok, value}} -> {name, value} end)}
      errors -> {:error, errors}
    end
  end

  # WF-32
  @doc "Returns true when a rendered key is one a counter can carry: non-empty text of at most 256 bytes."
  @spec key?(term()) :: boolean()
  def key?(key), do: is_binary(key) and key != "" and byte_size(key) <= @key_bytes

  # WF-32
  # WF-37
  # WF-45
  @doc "The window a counter opens at `now` for a configuration: `{:anchored, ms}`, `{:until, at}`, `{:span, start, end}` for a calendar window in `zone`, `:passed` for an `until` in the past or `{:error, :out_of_range}` for an `until` more than 31 days ahead."
  @spec bounds(t(), DateTime.t(), String.t() | nil, DateTime.t() | nil) ::
          bounds() | :passed | {:error, :out_of_range | :time_zone_required}
  def bounds(config, now, zone, until \\ nil)

  def bounds(%{window: {:window, ms}}, _now, _zone, _until), do: {:anchored, ms}

  def bounds(%{window: {:until, _pointer}}, %DateTime{} = now, _zone, %DateTime{} = until) do
    cond do
      DateTime.compare(until, now) != :gt -> :passed
      DateTime.diff(until, now, :millisecond) > @max_ms -> {:error, :out_of_range}
      true -> {:until, until}
    end
  end

  def bounds(%{window: {:until, _pointer}}, _now, _zone, nil), do: :passed

  def bounds(%{window: {:calendar, _unit}}, _now, nil, _until), do: {:error, :time_zone_required}

  def bounds(%{window: {:calendar, unit}}, %DateTime{} = now, zone, _until) do
    today = now |> DateTime.shift_zone!(zone) |> DateTime.to_date()
    first = if unit == :week, do: Date.beginning_of_week(today, :monday), else: today
    next = Date.add(first, if(unit == :week, do: 7, else: 1))
    {:span, midnight(first, zone), midnight(next, zone)}
  end

  defp midnight(date, zone) do
    naive = NaiveDateTime.new!(date, ~T[00:00:00])

    case DateTime.from_naive(naive, zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, later} -> DateTime.shift_zone!(later, "Etc/UTC")
    end
  end

  defp key(key) do
    if key?(key),
      do: {:ok, key},
      else: {:error, "invalid_value", "the key is a non-empty string of at most 256 bytes"}
  end

  defp limit(n) when is_integer(n) and n >= 1 do
    if n <= @limit["max"],
      do: {:ok, n},
      else: {:error, "out_of_range", "the limit is from 1 to 10000"}
  end

  defp limit(_n), do: {:error, "invalid_value", "the limit is an integer from 1 to 10000"}

  defp window(step) do
    case Enum.filter(~w(window until calendar), &Map.has_key?(step, &1)) do
      ["window"] -> duration(step["window"])
      ["until"] -> pointer(step["until"])
      ["calendar"] -> calendar(step["calendar"])
      _other -> {:error, "invalid_value", "exactly one of window, until or calendar"}
    end
  end

  defp duration(text) do
    case Span.ms(text) do
      {:ok, ms} when ms <= @max_ms -> {:ok, {:window, ms}}
      {:ok, _ms} -> {:error, "out_of_range", "a throttle window is at most 31 days"}
      :error -> {:error, "invalid_format", "an ISO 8601 duration of weeks, days and time"}
    end
  end

  defp pointer("/" <> _rest = pointer), do: {:ok, {:until, pointer}}
  defp pointer(_other), do: {:error, "invalid_format", "until is an RFC 6901 pointer"}

  defp calendar("day"), do: {:ok, {:calendar, :day}}
  defp calendar("week"), do: {:ok, {:calendar, :week}}
  defp calendar(_other), do: {:error, "invalid_value", "calendar is day or week"}
end
