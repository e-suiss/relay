defmodule Relay.Agents.Live.Store do
  @moduledoc """
  Data access of decision request delivery: the delivery of a request with its notification and recipient, and the deliveries an invitation or a whole waitpoint opened. An invitation's notification is found by its deduplication key, which names the invitation. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @copies """
  SELECT d.id, d.channel::text AS channel, d.recipient_id, d.target_id, d.provider,
    d.delivery_rank, d.failure_kind
  FROM relay.waitpoint_invitations i
  JOIN relay.notifications n ON n.tenant_id = i.tenant_id AND n.environment = i.environment
    AND n.recipient_id = i.recipient_id AND n.dedup_key = $2 || i.id::text
  JOIN relay.deliveries d ON d.tenant_id = n.tenant_id AND d.environment = n.environment
    AND d.notification_id = n.id
  """

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # INV-2
  @doc "Rolls the current transaction back with `reason`, so nothing of a request that could not be opened whole stays."
  @spec rollback(term()) :: no_return()
  def rollback(reason), do: Repo.rollback(reason)

  # AG-29
  # AG-34
  @doc "What the content of a delivery is produced from: its channel and recipient, the recipient's locale and the subject, deduplication key, sender type and event of its notification; `nil` when there is no such delivery."
  @spec delivery(Relay.Id.t()) :: map() | nil
  def delivery(delivery_id) do
    sql = """
    SELECT d.id, d.channel::text AS channel, d.recipient_id, n.subject_type, n.subject_id,
      n.dedup_key, n.sender_type, n.event_id, r.locale
    FROM relay.deliveries d
    JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
      AND n.id = d.notification_id
    JOIN relay.recipients r ON r.tenant_id = d.tenant_id AND r.environment = d.environment
      AND r.id = d.recipient_id
    WHERE d.id = $1
    """

    List.first(maps(Repo.scoped_query!(sql, [delivery_id])))
  end

  # AG-63
  @doc "The deliveries the notification of one invitation opened, with their rank and failure; `prefix` is the prefix of an invitation's deduplication key."
  @spec invitation_copies(Relay.Id.t(), String.t()) :: [map()]
  def invitation_copies(invitation_id, prefix),
    do: maps(Repo.scoped_query!(@copies <> " WHERE i.id = $1", [invitation_id, prefix]))

  # AG-35
  # INV-35
  @doc "The deliveries the notifications of every invitation of a waitpoint opened, with their rank and failure."
  @spec waitpoint_copies(Relay.Id.t(), String.t()) :: [map()]
  def waitpoint_copies(waitpoint_id, prefix) do
    sql = @copies <> " WHERE i.waitpoint_id = $1 ORDER BY d.id"
    maps(Repo.scoped_query!(sql, [waitpoint_id, prefix]))
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
