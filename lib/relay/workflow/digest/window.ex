defmodule Relay.Workflow.Digest.Window do
  @moduledoc """
  The pure core of a digest window (WF-26 … WF-31). `config/2` reads the fields of a `digest` step: `mode` (`fixed`, `sliding`, `scheduled`), `debounce` and `max_wait` (ISO 8601 durations, at most P31D), `schedule` (the `DAILY`/`WEEKLY` RRULE subset of `Relay.Workflow.Digest.Schedule`), `max_items` (2–1000) and `leading` (`immediate` or `none`, default `none`). A `fixed` window lasts `max_wait` from its first event; a `sliding` window needs `debounce` and `max_wait` and fires at `min(last + debounce, first + max_wait)`; a `scheduled` window fires at the next occurrence of its schedule after its first event, in the recipient's time zone. Reaching `max_items` closes a window at once. No window stays open longer than 31 days after its first event (WF-37, INV-32).

  The classes `security`, `transactional` and `action_required` are never digested (WF-28). The default windows by use (WF-31) are data here, a POLICY DEFAULT tuned by measurement. `render/3` shapes the data a digest template sees: `total_activities` (the running total since the recipient last read this key, WF-29), `window_activities`, `total_actors` and the first and last activities, at most 50 each.
  """

  alias Relay.Workflow.Digest.Schedule
  alias Relay.Workflow.Span

  @exempt ~w(security transactional action_required)
  @max_open_ms Relay.Limits.seconds!(["digest", "max_window"]) * 1_000
  @items Relay.Limits.fetch!(["digest", "max_items"])
  @render_max Relay.Limits.fetch!(["digest", "max_render_items"])

  @defaults %{
    "direct_message" => %{"mode" => "sliding", "debounce" => "PT30S", "max_wait" => "PT5M"},
    "group_message" => %{"mode" => "sliding", "debounce" => "PT2M", "max_wait" => "PT15M"},
    "mention" => %{"mode" => "sliding", "debounce" => "PT1M", "max_wait" => "PT10M"},
    "comment" => %{"mode" => "sliding", "debounce" => "PT5M", "max_wait" => "PT1H"},
    "daily_summary" => %{"mode" => "scheduled"},
    "weekly_summary" => %{"mode" => "scheduled"}
  }

  @type mode :: :fixed | :sliding | :scheduled
  @type t :: %{
          mode: mode(),
          leading: :immediate | :none,
          debounce_ms: pos_integer() | nil,
          max_wait_ms: pos_integer() | nil,
          schedule: String.t() | nil,
          max_items: pos_integer() | nil,
          release_at: DateTime.t() | nil
        }
  @type state :: %{
          required(:first_at) => DateTime.t(),
          required(:last_at) => DateTime.t(),
          required(:item_count) => non_neg_integer(),
          optional(atom()) => term()
        }
  @type field_error :: %{pointer: String.t(), code: String.t(), detail: String.t()}

  # WF-28
  # WF-36
  # E-11
  @doc "Returns true for a message class that is never digested."
  @spec exempt?(term()) :: boolean()
  def exempt?(class) when is_atom(class) and not is_nil(class), do: exempt?(Atom.to_string(class))
  def exempt?(class), do: class in @exempt

  # WF-28
  @doc "The message classes that are never digested."
  @spec exempt_classes() :: [String.t(), ...]
  def exempt_classes, do: @exempt

  # INV-32
  # WF-37
  @doc "The longest time a window stays open after its first event, in milliseconds."
  @spec max_open_ms() :: pos_integer()
  def max_open_ms, do: @max_open_ms

  # WF-31
  @doc "The default digest windows by use, as step fields; a `scheduled` default takes its `schedule` from the tenant."
  @spec defaults() :: %{String.t() => map()}
  def defaults, do: @defaults

  # WF-26
  # WF-59
  @doc "Reads the fields of a `digest` step into a window configuration, or returns its field errors under `pointer`."
  @spec config(map(), String.t()) :: {:ok, t()} | {:error, [field_error(), ...]}
  def config(step, pointer \\ "") when is_map(step) do
    fields = [
      mode: mode(step["mode"]),
      leading: leading(Map.get(step, "leading", "none")),
      debounce_ms: duration(step["debounce"]),
      max_wait_ms: duration(step["max_wait"]),
      schedule: schedule(step["schedule"]),
      max_items: max_items(step["max_items"])
    ]

    config = Map.new(fields, &value/1)

    invalid =
      for {name, {:error, code, detail}} <- fields,
          do: %{pointer: "#{pointer}/#{name(name)}", code: code, detail: detail}

    missing =
      for field <- required(config.mode),
          is_nil(step[field]),
          do: %{pointer: "#{pointer}/#{field}", code: "required", detail: "#{field} is required"}

    case invalid ++ missing do
      [] -> {:ok, Map.put(config, :release_at, nil)}
      errors -> {:error, errors}
    end
  end

  # PC-46
  # WF-42
  @doc "A fixed window released at `release_at`: the window of the deliveries a recipient's quiet hours held back."
  @spec release(DateTime.t()) :: t()
  def release(%DateTime{} = release_at) do
    %{
      mode: :fixed,
      leading: :none,
      debounce_ms: nil,
      max_wait_ms: nil,
      schedule: nil,
      max_items: nil,
      release_at: release_at
    }
  end

  # PC-46
  # WF-42
  # WF-58
  @doc "The release time of a recipient's held-back deliveries when its quiet hours end at `ends_at`: the end plus the deterministic release jitter over `spread_ms`, keyed by the local wall-clock time of the end in `zone`."
  @spec release_at(Relay.Scope.t(), Relay.Id.t(), DateTime.t(), String.t(), non_neg_integer()) ::
          DateTime.t()
  def release_at(%Relay.Scope{} = scope, recipient_id, %DateTime{} = ends_at, zone, spread_ms)
      when is_integer(spread_ms) and spread_ms >= 0 do
    %Relay.Scope{tenant_id: tenant_id, environment: environment} = scope
    local = ends_at |> DateTime.shift_zone!(zone) |> DateTime.to_naive()
    text = NaiveDateTime.to_iso8601(local)
    offset = Relay.Jitter.release(tenant_id, environment, recipient_id, text, spread_ms)
    DateTime.add(ends_at, offset, :millisecond)
  end

  # WF-26
  # WF-27
  # INV-32
  @doc "When a window fires: `max_items` reached fires at the last event, otherwise by its mode; never after its deadline."
  @spec fire_at(t(), state(), String.t() | nil) :: DateTime.t()
  def fire_at(config, %{first_at: first, last_at: last, item_count: count} = state, zone) do
    deadline = Map.get(state, :deadline_at) || DateTime.add(first, @max_open_ms, :millisecond)
    full? = is_integer(config.max_items) and count >= config.max_items
    at = if full?, do: last, else: by_mode(config, first, last, zone)
    if DateTime.compare(at, deadline) == :gt, do: deadline, else: at
  end

  defp by_mode(%{release_at: %DateTime{} = at}, _first, _last, _zone), do: at

  defp by_mode(%{mode: :fixed, max_wait_ms: wait}, first, _last, _zone),
    do: DateTime.add(first, wait, :millisecond)

  defp by_mode(%{mode: :sliding, debounce_ms: debounce, max_wait_ms: wait}, first, last, _zone) do
    quiet = DateTime.add(last, debounce, :millisecond)
    cap = DateTime.add(first, wait, :millisecond)
    if DateTime.compare(quiet, cap) == :lt, do: quiet, else: cap
  end

  defp by_mode(%{mode: :scheduled, schedule: text}, first, _last, zone) do
    {:ok, rule} = Schedule.parse(text)
    Schedule.next(rule, first, zone)
  end

  # WF-26
  # WF-29
  @doc "The data a digest template sees: totals and the first and last `n` activities (at most 50 each)."
  @spec render(map(), map(), pos_integer()) :: map()
  def render(window, items, n \\ @render_max) do
    n = n |> max(1) |> min(@render_max)

    %{
      "total_activities" => window.cumulative_count,
      "window_activities" => window.item_count,
      "total_actors" => items.actors,
      "first_activities" => Enum.map(Enum.take(items.first, n), &activity/1),
      "last_activities" => Enum.map(Enum.take(items.last, -n), &activity/1),
      "collapse_key" => Base.encode16(window.window_key, case: :lower)
    }
  end

  defp activity(item) do
    %{
      "notification_id" => item.notification_id,
      "delivery_id" => item.delivery_id,
      "occurred_at" => item.occurred_at
    }
  end

  defp value({name, {:ok, value}}), do: {name, value}
  defp value({name, _error}), do: {name, nil}

  defp required(:fixed), do: ["max_wait"]
  defp required(:sliding), do: ["debounce", "max_wait"]
  defp required(:scheduled), do: ["schedule"]
  defp required(_invalid), do: []

  defp name(:debounce_ms), do: "debounce"
  defp name(:max_wait_ms), do: "max_wait"
  defp name(other), do: Atom.to_string(other)

  defp mode("fixed"), do: {:ok, :fixed}
  defp mode("sliding"), do: {:ok, :sliding}
  defp mode("scheduled"), do: {:ok, :scheduled}
  defp mode(_other), do: {:error, "invalid_value", "mode is fixed, sliding or scheduled"}

  defp leading("immediate"), do: {:ok, :immediate}
  defp leading("none"), do: {:ok, :none}
  defp leading(_other), do: {:error, "invalid_value", "leading is immediate or none"}

  defp duration(nil), do: {:ok, nil}

  defp duration(text) do
    case Span.ms(text) do
      {:ok, ms} when ms <= @max_open_ms -> {:ok, ms}
      {:ok, _ms} -> {:error, "out_of_range", "a digest window is at most 31 days"}
      :error -> {:error, "invalid_format", "an ISO 8601 duration of weeks, days and time"}
    end
  end

  defp schedule(nil), do: {:ok, nil}

  defp schedule(text) do
    case Schedule.parse(text) do
      {:ok, _rule} -> {:ok, text}
      :error -> {:error, "invalid_format", "a DAILY or WEEKLY rule with BYHOUR"}
    end
  end

  defp max_items(nil), do: {:ok, nil}

  defp max_items(n) when is_integer(n) do
    if n >= @items["min"] and n <= @items["max"],
      do: {:ok, n},
      else: {:error, "out_of_range", "max_items is from 2 to 1000"}
  end

  defp max_items(_other), do: {:error, "invalid_type", "max_items is an integer"}
end
