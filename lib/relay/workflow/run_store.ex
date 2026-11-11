defmodule Relay.Workflow.RunStore do
  @moduledoc """
  Data access of workflow runs (WF-59 (5), WF-43) through the `relay_fn.workflow_run_*` functions inside `Relay.Repo.in_scope/3`, the read of a run with its pinned version and its notification, the projection of the deliveries a run opened, and the cross-tenant discovery of scopes with a due run through `relay_ops.workflow_run_due_scopes`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @start [:started, :exists, :notification_not_found]
  @save [:saved, :version_conflict, :already_final, :not_found]
  @manager [:changed, :unchanged, :version_conflict, :not_found]

  @run """
  SELECT r.tenant_id, r.environment, r.id, r.notification_id, r.workflow_id,
    r.workflow_version_id, r.plan, r.step_cursor, r.step_results, r.state, r.wake_at, r.outcome,
    r.rule_id, r.started_at, r.finished_at, r.version, v.definition, v.version_no,
    w.key AS workflow_key, n.recipient_id, n.event_id, n.state AS notification_state,
    n.expires_at, n.message_class::text AS message_class, n.subtenant_id,
    e.created_at AS event_created_at
  FROM relay.workflow_runs r
  JOIN relay.workflow_versions v ON v.tenant_id = r.tenant_id AND v.environment = r.environment
    AND v.id = r.workflow_version_id
  JOIN relay.workflows w ON w.tenant_id = r.tenant_id AND w.environment = r.environment
    AND w.id = r.workflow_id
  JOIN relay.notifications n ON n.tenant_id = r.tenant_id AND n.environment = r.environment
    AND n.id = r.notification_id
  LEFT JOIN relay.events e ON e.tenant_id = n.tenant_id AND e.environment = n.environment
    AND e.id = n.event_id
  """

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Rolls the current transaction back with `reason`."
  @spec rollback(term()) :: no_return()
  def rollback(reason), do: Repo.rollback(reason)

  # WF-59 (5)
  @doc "Records a run of a notification in the state its first advancement left it."
  @spec start(map()) :: {:started | :exists | :notification_not_found, Relay.Id.t() | nil}
  def start(run) do
    [row] =
      Repo.call!("relay_fn.workflow_run_start", [
        run.id,
        run.notification_id,
        run.plan,
        run.cursor,
        run.results,
        run.state,
        run.wake_at,
        run.outcome,
        run.rule_id,
        run.started_at
      ])

    {Repo.code!(row["result"], @start), row["run_id"]}
  end

  # WF-43
  @doc "Takes the run's advisory lock for the rest of the transaction."
  @spec lock(Relay.Id.t()) :: :locked
  def lock(run_id) do
    [row] = Repo.call!("relay_fn.workflow_run_lock", [run_id])
    Repo.code!(row["workflow_run_lock"], [:locked])
  end

  # WF-59 (5)
  @doc "Reads a run with its pinned version's definition, its workflow key and its notification; `nil` when there is none."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(run_id), do: one(@run <> " WHERE r.id = $1", [run_id])

  @doc "Reads the run of a notification; `nil` when there is none."
  @spec by_notification(Relay.Id.t()) :: map() | nil
  def by_notification(notification_id),
    do: one(@run <> " WHERE r.notification_id = $1", [notification_id])

  # WF-29
  @doc "Reads the run of the notification a delivery belongs to; `nil` when there is none."
  @spec by_delivery(Relay.Id.t()) :: map() | nil
  def by_delivery(delivery_id) do
    one(
      @run <>
        " WHERE r.notification_id = (SELECT d.notification_id FROM relay.deliveries d WHERE d.id = $1)",
      [delivery_id]
    )
  end

  # WF-15
  @doc "The running or waiting run whose routes opened a delivery; `nil` when there is none."
  @spec routing_run(Relay.Id.t()) :: Relay.Id.t() | nil
  def routing_run(delivery_id) do
    """
    SELECT r.tenant_id, r.environment, r.id FROM relay.workflow_runs r
    JOIN relay.deliveries d ON d.tenant_id = r.tenant_id AND d.environment = r.environment
      AND d.notification_id = r.notification_id
    WHERE d.id = $1 AND r.state IN ('running', 'waiting')
      AND r.step_cursor -> 'routes' <> '{}'::jsonb
    """
    |> Repo.scoped_query!([delivery_id])
    |> maps()
    |> case do
      [%{"id" => id}] -> id
      [] -> nil
    end
  end

  # WF-59 (5)
  @doc "Saves an advanced run under its version."
  @spec save(Relay.Id.t(), pos_integer(), map()) ::
          {:saved | :version_conflict | :already_final | :not_found, pos_integer() | nil}
  def save(run_id, version, run) do
    [row] =
      Repo.call!("relay_fn.workflow_run_save", [
        run_id,
        version,
        run.cursor,
        run.results,
        run.state,
        run.wake_at,
        run.outcome,
        run.rule_id
      ])

    {Repo.code!(row["result"], @save), row["version"]}
  end

  # API-57
  @doc "Cancels the running and waiting runs of an event, a notification or a cancellation key (optionally narrowed to recipients); returns how many."
  @spec cancel(map()) :: non_neg_integer()
  def cancel(filter) do
    [row] =
      Repo.call!("relay_fn.workflow_run_cancel", [
        Map.get(filter, :event_id),
        Map.get(filter, :notification_id),
        Map.get(filter, :cancellation_key),
        Map.get(filter, :recipient_ids)
      ])

    row["workflow_run_cancel"]
  end

  # WF-43
  @doc "The waiting runs of the scope whose wake time has come in business time, oldest first."
  @spec due(pos_integer()) :: [{Relay.Id.t(), DateTime.t()}]
  def due(limit) do
    for row <- Repo.call!("relay_fn.workflow_run_due", [limit]),
        do: {row["run_id"], row["wake_at"]}
  end

  # WF-43
  # TN-13 (4)
  @doc "Lists the scopes that have a due run, through the discovery escape hatch; scopes only, no content."
  @spec due_scopes(pos_integer()) :: [{Relay.Id.t(), String.t()}]
  def due_scopes(limit) when is_integer(limit) and limit > 0 do
    for row <-
          Repo.call_unscoped!(
            :workflow_run_due_discovery,
            "relay_ops.workflow_run_due_scopes",
            [limit]
          ),
        do: {row["tenant_id"], row["environment"]}
  end

  # WF-60
  # WF-22
  @doc "The current projection of deliveries by identifier: `status`, and whether each was seen, read or clicked by a human."
  @spec deliveries([Relay.Id.t()]) :: %{Relay.Id.t() => map()}
  def deliveries([]), do: %{}

  def deliveries(ids) do
    """
    SELECT d.tenant_id, d.environment, d.id, relay_private.delivery_status(d) AS status,
      d.seen_at IS NOT NULL AS seen, d.read_at IS NOT NULL AS read,
      coalesce(d.clicked_by = 'human', false) AS clicked
    FROM relay.deliveries d WHERE d.id = ANY ($1)
    """
    |> Repo.scoped_query!([ids])
    |> maps()
    |> Map.new(&{&1["id"], &1})
  end

  # WF-4
  @doc "Changes the single manager of a workflow; audited as `workflow.manager_changed`."
  @spec manager_set(String.t(), String.t(), pos_integer() | nil, <<_::256>>, Actor.t()) ::
          {:changed | :unchanged | :version_conflict | :not_found, pos_integer() | nil}
  def manager_set(key, managed_by, expected_version, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.workflow_manager_set",
        [key, managed_by, expected_version, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], @manager), row["version"]}
  end

  defp one(sql, params) do
    case maps(Repo.scoped_query!(sql, params)) do
      [row] -> row
      [] -> nil
    end
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
