defmodule Relay.Workflow.RecurrenceStore do
  @moduledoc """
  Data access of recurrence rules and their occurrence records (WF-48, WF-49, WF-61). Writes call the `relay_fn.recurrence_*` functions; reads select the rules, their last occurrence and the time zones a rule runs in. Every function except `in_scope/2` and `due_scopes/2` runs inside `Relay.Repo.in_scope/3`. Times are UTC; the local start of a rule is stored as text and never converted in SQL (WF-47).
  """

  alias Relay.Actor
  alias Relay.Repo

  @type digest :: <<_::256>>

  @columns """
  r.id, r.workflow_id, r.workflow_key, r.target_kind, r.recipient_id, r.topic_key, r.rrule,
  r.dtstart, r.timezone, r.data_ct, r.data_key_id, r.state, r.next_at, r.next_ordinal,
  r.next_zone, r.fire_at, r.occurrence_count, r.last_occurrence_at, r.cancel_reason,
  r.cancelled_at, r.completed_at, r.created_by, r.version, r.created_at, r.updated_at
  """

  @last """
  SELECT DISTINCT ON (o.recurrence_id) o.recurrence_id, o.occurrence_at, o.ordinal, o.outcome,
    o.rule_id, o.error_code, o.event_id, o.recorded_at
  FROM relay.recurrence_occurrences o
  WHERE o.recurrence_id = ANY ($1::uuid[])
  ORDER BY o.recurrence_id, o.occurrence_at DESC
  """

  @recipient "SELECT r.timezone, r.state FROM relay.recipients r WHERE r.id = $1"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Queues a job inside the current transaction; rolls the transaction back when it is not queued."
  @spec insert_job!(Ecto.Changeset.t()) :: :ok
  def insert_job!(changeset) do
    case Oban.insert(changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:job_not_queued, reason})
    end
  end

  # WF-48
  # WF-61
  @doc "Records a new rule with its first occurrence and timer; `:limit_reached` when the scope already holds `max_active` active rules."
  @spec create(map(), pos_integer(), digest(), Actor.t()) :: :created | :limit_reached
  def create(r, max_active, digest, %Actor{} = actor) do
    params =
      [
        r.id,
        r.workflow_id,
        r.workflow_key,
        r.target_kind,
        r.recipient_id,
        r.topic_key,
        r.rrule,
        r.dtstart,
        r.timezone,
        r.data_ct,
        r.data_key_id,
        r.next_at,
        r.next_ordinal,
        r.next_zone,
        r.fire_at,
        max_active,
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.recurrence_create", params)
    Repo.code!(row["recurrence_create"], [:created, :limit_reached])
  end

  # WF-49
  @doc "Cancels an active rule with `request` or `subject_erasure`; its timer finds it closed."
  @spec cancel(Relay.Id.t(), String.t(), digest(), Actor.t()) :: :cancelled | :closed | :not_found
  def cancel(id, reason, digest, %Actor{} = actor) do
    [row] = Repo.call!("relay_fn.recurrence_cancel", [id, reason, digest] ++ Actor.params(actor))
    Repo.code!(row["recurrence_cancel"], [:cancelled, :closed, :not_found])
  end

  # WF-49
  # WF-61
  @doc "Records the due occurrences of an active rule whose next occurrence is still `expected_next_at` and moves it to `next` (`nil` completes it); `:stale` when another run moved it first."
  @spec fire(Relay.Id.t(), DateTime.t(), [map()], map() | nil) ::
          :advanced | :completed | :stale | :not_found
  def fire(id, expected_next_at, occurrences, next) do
    {next_at, ordinal, zone, fire_at} =
      case next do
        nil -> {nil, nil, nil, nil}
        n -> {n.at, n.ordinal, n.zone, n.fire_at}
      end

    params = [
      id,
      expected_next_at,
      Enum.map(occurrences, & &1.at),
      Enum.map(occurrences, & &1.ordinal),
      Enum.map(occurrences, & &1.outcome),
      Enum.map(occurrences, &Map.get(&1, :rule_id)),
      Enum.map(occurrences, &Map.get(&1, :error_code)),
      Enum.map(occurrences, &Map.get(&1, :event_id)),
      next_at,
      ordinal,
      zone,
      fire_at
    ]

    [row] = Repo.call!("relay_fn.recurrence_fire", params)
    Repo.code!(row["recurrence_fire"], [:advanced, :completed, :stale, :not_found])
  end

  @doc "Reads a rule of the established scope, or `nil`."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(id) do
    one("SELECT #{@columns} FROM relay.recurrences r WHERE r.id = $1", [id])
  end

  # API-56
  @doc "A page of rules newest first from a decoded cursor; at most `limit + 1` rows come back."
  @spec page(map() | nil, pos_integer()) :: [map()]
  def page(nil, limit) do
    all(
      "SELECT #{@columns} FROM relay.recurrences r ORDER BY r.created_at DESC, r.id DESC LIMIT $1",
      [limit + 1]
    )
  end

  def page(%{direction: :after, sort_ts_us: ts, id: id}, limit) do
    all(
      "SELECT #{@columns} FROM relay.recurrences r WHERE (r.created_at, r.id) < ($1, $2) ORDER BY r.created_at DESC, r.id DESC LIMIT $3",
      [DateTime.from_unix!(ts, :microsecond), id, limit + 1]
    )
  end

  def page(%{direction: :before, sort_ts_us: ts, id: id}, limit) do
    "SELECT #{@columns} FROM relay.recurrences r WHERE (r.created_at, r.id) > ($1, $2) ORDER BY r.created_at, r.id LIMIT $3"
    |> all([DateTime.from_unix!(ts, :microsecond), id, limit + 1])
    |> Enum.reverse()
  end

  # WF-61
  @doc "The last recorded occurrence of each rule of `ids`, by rule identifier."
  @spec last_occurrences([Relay.Id.t()]) :: %{Relay.Id.t() => map()}
  def last_occurrences([]), do: %{}

  def last_occurrences(ids), do: Map.new(all(@last, [ids]), &{&1["recurrence_id"], &1})

  # WF-61
  @doc "The recorded occurrences of a rule, oldest first, at most `limit`."
  @spec occurrences(Relay.Id.t(), pos_integer()) :: [map()]
  def occurrences(id, limit) do
    all(
      """
      SELECT o.occurrence_at, o.ordinal, o.outcome, o.rule_id, o.error_code, o.event_id
      FROM relay.recurrence_occurrences o WHERE o.recurrence_id = $1
      ORDER BY o.occurrence_at LIMIT $2
      """,
      [id, limit]
    )
  end

  # WF-43
  @doc "The identifiers of the active rules whose timer is due at `now`, earliest first."
  @spec due(DateTime.t(), pos_integer()) :: [Relay.Id.t()]
  def due(now, limit) do
    for row <-
          all(
            "SELECT r.id FROM relay.recurrences r WHERE r.state = 'active' AND r.fire_at <= $1 ORDER BY r.fire_at LIMIT $2",
            [now, limit]
          ),
        do: row["id"]
  end

  # WF-45
  @doc "The stored time zone and state of a recipient and the tenant's `default_timezone`; `recipient_id` may be `nil`."
  @spec zones(Relay.Id.t() | nil) :: %{
          recipient: String.t() | nil,
          recipient_state: String.t() | nil,
          tenant: String.t() | nil
        }
  def zones(recipient_id) do
    %Relay.Scope{tenant_id: tenant_id} = Repo.current_scope()
    tenant = one("SELECT t.default_timezone FROM relay.tenants t WHERE t.id = $1", [tenant_id])
    recipient = recipient_id && one(@recipient, [recipient_id])

    %{
      recipient: recipient && recipient["timezone"],
      recipient_state: recipient && recipient["state"],
      tenant: tenant && tenant["default_timezone"]
    }
  end

  # WF-43
  # TN-13 (4)
  @doc "Lists the scopes that have an active rule whose timer passed at least `min_age_ms` ago in business time, through the discovery escape hatch; scopes only, no content."
  @spec due_scopes(non_neg_integer(), pos_integer()) :: [{Relay.Id.t(), String.t()}]
  def due_scopes(min_age_ms, limit) when is_integer(limit) and limit > 0 do
    for row <-
          Repo.call_unscoped!(
            :recurrence_due_discovery,
            "relay_ops.recurrence_due_scopes",
            [min_age_ms, limit]
          ),
        do: {row["tenant_id"], row["environment"]}
  end

  defp one(sql, params) do
    case all(sql, params) do
      [row] -> row
      [] -> nil
    end
  end

  defp all(sql, params), do: maps(Repo.scoped_query!(sql, params))

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
