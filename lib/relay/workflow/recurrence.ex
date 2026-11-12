defmodule Relay.Workflow.Recurrence do
  @moduledoc """
  Recurrence rules (C-52, WF-48, WF-49, WF-61). A rule sends one workflow to one subscriber or to one topic on the occurrences of an RRULE (`Relay.Workflow.RRule`) counted from a local start time. It is a definition row whose next occurrence is a column with a timer (C-8, WF-43): no message waits for it and no job runs until it is due. Each occurrence is sent with the version of the workflow published at that moment (WF-49).

  * **Time zone.** A subscriber rule runs in the subscriber's zone (WF-45): the zone of the subscriber's profile, else the tenant's `default_timezone`. A topic rule runs in its own `timezone`, else the tenant's `default_timezone` (WF-61). The zone is resolved again whenever the next occurrence is computed, and the zone used is kept with it.
  * **Jitter.** The timer of an occurrence fires `Relay.Jitter.recurrence/5` after it, within the `recurrence.jitter_spread` limit (PT60S, WF-58), shrunk or zeroed by the tenant's jitter control (`Relay.Timing`), so rules due at the same minute spread over it instead of piling on the write path (WF-42, L-43).
  * **Missed occurrences.** When a timer runs late, every occurrence since the rule's next one up to now is due. Only the last of them is sent, and only when it is at most `recurrence.missed_grace` (PT1H) late; the others are recorded `missed` with `recurrence.missed` (WF-61). At most 1000 due occurrences are recorded in one run.
  * **Limits.** `UNTIL` and `DTSTART` lie at most `recurrence.max_until_years` (5) years ahead and `DTSTART` at most as many years back; a tenant environment holds at most `recurrence.max_active_per_environment` (100000) active rules (PD).
  """

  alias Relay.Workflow.RecurrenceStore, as: Store
  alias Relay.Workflow.RRule

  @spread_ms Relay.Limits.seconds!(["recurrence", "jitter_spread"]) * 1000
  @grace_s Relay.Limits.seconds!(["recurrence", "missed_grace"])
  @max_years Relay.Limits.fetch!(["recurrence", "max_until_years"])
  @max_active Relay.Limits.fetch!(["recurrence", "max_active_per_environment"])
  @max_due 1000
  @dtstart ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?\z/

  @type next :: %{
          at: DateTime.t(),
          ordinal: pos_integer() | nil,
          zone: String.t(),
          fire_at: DateTime.t()
        }
  @type occurrence :: %{at: DateTime.t(), ordinal: pos_integer() | nil}
  @type input :: %{
          id: Relay.Id.t(),
          rrule: term(),
          dtstart: term(),
          timezone: term(),
          target_kind: String.t(),
          recipient_id: Relay.Id.t() | nil,
          now: DateTime.t()
        }
  @type planned :: %{
          rrule: String.t(),
          dtstart: String.t(),
          timezone: String.t() | nil,
          next: next()
        }
  @type due ::
          :inactive
          | :not_due
          | {:recipient_erased, map()}
          | {:due,
             %{
               row: map(),
               send: occurrence() | nil,
               missed: [occurrence()],
               next: next() | nil
             }}

  @doc "The most active rules a tenant environment may hold."
  @spec max_active() :: pos_integer()
  def max_active, do: @max_active

  # WF-61
  # WF-45
  # WF-58
  @doc "Checks a new rule and computes its first occurrence after `now` and its timer inside the caller's scoped transaction; the errors are field errors of `validation_failed`."
  @spec plan(Relay.Scope.t(), input()) :: {:ok, planned()} | {:error, Relay.Error.t()}
  def plan(scope, input) do
    {rule, rule_errors} = rule(input.rrule, input.now)
    {dtstart, dtstart_errors} = dtstart(input.dtstart, input.now)
    {timezone, zone_errors} = timezone(input.timezone, input.target_kind)

    with [] <- rule_errors ++ dtstart_errors ++ zone_errors,
         {:ok, zone} <- zone(input.target_kind, timezone, Store.zones(input.recipient_id)),
         {:ok, next} <- first(rule, dtstart, zone, input.now) do
      {:ok,
       %{
         rrule: RRule.to_string(rule),
         dtstart: NaiveDateTime.to_iso8601(dtstart),
         timezone: timezone,
         next: with_timer(scope, input.id, next, zone)
       }}
    else
      [_ | _] = errors -> invalid(errors)
      {:error, %Relay.Error{}} = error -> error
    end
  end

  # WF-49
  # WF-61
  @doc "Reads a rule inside the caller's scoped transaction and works out what is due at `now`: the occurrence to send, the missed ones and the next occurrence with its timer (`nil` when the rule is over)."
  @spec due(Relay.Scope.t(), Relay.Id.t(), DateTime.t()) :: due() | {:error, Relay.Error.t()}
  def due(scope, id, now) do
    case Store.get(id) do
      %{"state" => "active"} = row -> due_row(scope, row, now)
      _missing_or_closed -> :inactive
    end
  end

  defp due_row(scope, row, now) do
    zones = Store.zones(row["recipient_id"])

    cond do
      DateTime.compare(row["fire_at"], now) == :gt ->
        :not_due

      row["target_kind"] == "subscriber" and zones.recipient_state != "active" ->
        {:recipient_erased, row}

      true ->
        with {:ok, zone} <- zone(row["target_kind"], row["timezone"], zones),
             do: {:due, occurrences(scope, row, zone, now)}
    end
  end

  defp occurrences(scope, row, zone, now) do
    {:ok, rule} = RRule.parse(row["rrule"])
    dtstart = NaiveDateTime.from_iso8601!(row["dtstart"])
    first = %{at: row["next_at"], ordinal: row["next_ordinal"]}

    later =
      rule
      |> RRule.between(dtstart, zone, row["next_at"], now, @max_due - 1)
      |> Enum.map(&Map.take(&1, [:at, :ordinal]))

    due = [first | later]
    last = List.last(due)

    {send, missed} =
      if DateTime.diff(now, last.at, :second) <= @grace_s,
        do: {last, Enum.drop(due, -1)},
        else: {nil, due}

    next =
      case RRule.next(rule, dtstart, zone, now) do
        {:ok, occurrence} -> with_timer(scope, row["id"], occurrence, zone)
        :none -> nil
      end

    %{row: row, send: send, missed: missed, next: next}
  end

  # WF-42
  # WF-58
  @doc "The timer instant of an occurrence of rule `id`, inside the caller's scoped transaction: the occurrence plus its deterministic jitter, within the spread the tenant's jitter control leaves (`Relay.Timing`)."
  @spec fire_at(Relay.Scope.t(), Relay.Id.t(), DateTime.t()) :: DateTime.t()
  def fire_at(scope, id, at) do
    spread = min(@spread_ms, Relay.Timing.spread(Relay.Timing.read(), :scheduled, nil))
    offset = Relay.Jitter.recurrence(scope.tenant_id, scope.environment, id, iso(at), spread)
    DateTime.add(at, offset, :millisecond)
  end

  @doc "The UTC text of an occurrence instant, to the second, as jitter, idempotency and dedup keys use it."
  @spec iso(DateTime.t()) :: String.t()
  def iso(at), do: DateTime.to_iso8601(%{at | microsecond: {0, 0}})

  defp with_timer(scope, id, occurrence, zone) do
    %{
      at: occurrence.at,
      ordinal: occurrence.ordinal,
      zone: zone,
      fire_at: fire_at(scope, id, occurrence.at)
    }
  end

  defp rule(text, now) do
    with {:ok, rule} <- RRule.parse(text),
         :ok <- RRule.check_horizon(rule, now, @max_years) do
      {rule, []}
    else
      {:error, errors} -> {nil, errors}
    end
  end

  defp dtstart(text, now) when is_binary(text) do
    with true <- Regex.match?(@dtstart, text),
         {:ok, naive} <- NaiveDateTime.from_iso8601(seconds(text)),
         :ok <- within_years(naive, now) do
      {naive, []}
    else
      {:error, :too_far} ->
        {nil, [field("/dtstart", "not_allowed", "lies more than #{@max_years} years away")]}

      _invalid ->
        {nil, [field("/dtstart", "invalid_format", "a local time such as 2026-11-11T09:00:00")]}
    end
  end

  defp dtstart(_text, _now),
    do: {nil, [field("/dtstart", "invalid_format", "a local time such as 2026-11-11T09:00:00")]}

  defp seconds(text), do: if(byte_size(text) == 16, do: text <> ":00", else: text)

  defp within_years(naive, now) do
    local = DateTime.to_naive(now)
    earliest = NaiveDateTime.shift(local, year: -@max_years)
    latest = NaiveDateTime.shift(local, year: @max_years)

    if NaiveDateTime.compare(naive, earliest) == :lt or
         NaiveDateTime.compare(naive, latest) == :gt,
       do: {:error, :too_far},
       else: :ok
  end

  defp timezone(nil, _kind), do: {nil, []}

  defp timezone(_zone, "subscriber"),
    do:
      {nil,
       [field("/timezone", "not_allowed", "a subscriber rule runs in the subscriber's time zone")]}

  defp timezone(zone, _kind) do
    case Relay.TimeZone.new(zone) do
      {:ok, canonical} -> {canonical, []}
      {:error, _error} -> {nil, [field("/timezone", "invalid_format", "not an IANA time zone")]}
    end
  end

  # WF-45
  defp zone(kind, timezone, zones) do
    candidates =
      if kind == "subscriber", do: [zones.recipient, zones.tenant], else: [timezone, zones.tenant]

    Enum.find_value(candidates, unavailable(), fn name ->
      case Relay.TimeZone.new(name) do
        {:ok, zone} -> {:ok, zone}
        {:error, _error} -> nil
      end
    end)
  end

  defp first(rule, dtstart, zone, now) do
    case RRule.next(rule, dtstart, zone, now) do
      {:ok, occurrence} -> {:ok, occurrence}
      :none -> invalid([field("/rrule", "not_allowed", "the rule has no occurrence after now")])
    end
  end

  defp unavailable,
    do:
      {:error,
       Relay.Error.new(:service_unavailable, "the time zone could not be read", %{
         retry_after: 1
       })}

  defp invalid(errors),
    do:
      {:error,
       Relay.Error.new(:validation_failed, "the rule breaks a field rule", %{
         errors: Enum.sort_by(errors, & &1.pointer)
       })}

  defp field(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}
end
