defmodule Relay.Agents.TaskStore do
  @moduledoc """
  Data access for the protocol face of the agents context: the read behind an A2A push notification of a mailbox record, and the recorded state of the tasks that registered sources notify Relay about (`relay_fn.agent_task_notification_apply`). Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @results [:applied, :duplicate, :stale, :source_not_found]

  @type id :: Relay.Id.t()
  @type result :: :applied | :duplicate | :stale | :source_not_found

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # AG-42
  # AG-21
  # AG-5
  @doc "Reads a mailbox record with the A2A push endpoint of the active agent that owns its mailbox and the state of the waitpoint it speaks of; `nil` when the mailbox is no agent's, the agent is not active or has no A2A push endpoint, or the record is unknown."
  @spec push_row(id(), id()) :: map() | nil
  def push_row(mailbox_id, record_id) do
    sql = """
    SELECT a.a2a_push_endpoint_id AS endpoint_id, r.id AS record_id, r.mailbox_id, r.epoch, r.seq,
      r.kind, r.event_type::text AS event_type, r.waitpoint_id, r.created_at,
      w.state AS waitpoint_state, w.kind AS waitpoint_kind, w.profile AS waitpoint_profile
    FROM relay.mailbox_records r
    JOIN relay.mailboxes m ON m.tenant_id = r.tenant_id AND m.environment = r.environment
      AND m.id = r.mailbox_id
    JOIN relay.agents a ON a.tenant_id = m.tenant_id AND a.environment = m.environment
      AND a.id = m.owner_ref
    LEFT JOIN relay.waitpoints w ON w.tenant_id = r.tenant_id AND w.environment = r.environment
      AND w.id = r.waitpoint_id
    WHERE r.id = $1 AND r.mailbox_id = $2 AND m.owner_kind = 'agent' AND a.state = 'active'
      AND a.a2a_push_endpoint_id IS NOT NULL AND r.kind IN ('message', 'waitpoint_event')
      AND r.created_at BETWEEN uuid_extract_timestamp($1) - interval '5 minutes'
        AND uuid_extract_timestamp($1) + interval '5 minutes'
    """

    sql |> all([record_id, mailbox_id]) |> List.first()
  end

  # AG-37
  # INV-35
  @doc "Applies a notification to the recorded state of its task: `params` are the source, the task, the protocol, the sequence number, the state, the receipt and whether the state was read at the source."
  @spec apply_notification([term()]) :: result()
  def apply_notification(params) when is_list(params) do
    [row] = Repo.call!("relay_fn.agent_task_notification_apply", params)
    Repo.code!(row["result"], @results)
  end

  # AG-37
  @doc "Reads the recorded state of a task of a source, or `nil`."
  @spec notification(id(), String.t()) :: map() | nil
  def notification(source_id, task) do
    sql = """
    SELECT n.task, n.protocol, n.seq, n.state, n.reconciled_at, n.updated_at
    FROM relay.agent_task_notifications n
    WHERE n.source_id = $1 AND n.task = $2
    """

    sql |> all([source_id, task]) |> List.first()
  end

  defp all(sql, params) do
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
