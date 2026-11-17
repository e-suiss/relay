defmodule Relay.Agents.FirstContactStore do
  @moduledoc """
  Data access of messages between agents: the `relay_fn.agent_message_send`, `relay_fn.agent_relationship_apply`, `relay_fn.agent_block_set` and `relay_fn.mailbox_abuse_report` functions and the reads of a message's metadata, the request box and the stored envelope. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @levels [:unknown, :known, :verified, :trusted]
  @sent [
    :sent,
    :self,
    :sender_not_found,
    :recipient_not_found,
    :recipient_inactive,
    :token_required,
    :token_invalid,
    :token_replayed,
    :rate_limited
  ]
  @message_columns "m.record_id, m.mailbox_id, m.recipient_agent_id, m.sender_agent_id, m.box, m.trust_label, m.relationship, m.content_encryption, m.size, m.first_contact, m.created_at"

  @type id :: Relay.Id.t()

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # AG-59
  # AG-60
  # AG-61
  @doc "Sends a message to an agent's mailbox; the database decides the box, checks the first-contact rate and spends the token."
  @spec send(map()) :: map()
  def send(message) do
    [row] =
      Repo.call!("relay_fn.agent_message_send", [
        message.id,
        message.recipient_id,
        message.sender_id,
        message.content_encryption,
        message.size,
        message.payload_ct,
        message.payload_tenant_key_id,
        message.payload_digest,
        Atom.to_string(message.token),
        message.token_digest,
        message.token_key_id,
        message.hour_limit,
        message.day_recipient_limit,
        message.traceparent
      ])

    %{
      result: Repo.code!(row["result"], @sent),
      box: row["box"],
      relationship: row["relationship"],
      epoch: row["epoch"],
      seq: row["seq"],
      retry_after: row["retry_after_seconds"],
      limit_name: row["limit_name"],
      actual: row["actual"]
    }
  end

  # AG-73
  @doc "Applies a relationship level of a pair under its sequence number."
  @spec apply_relationship(id(), id(), String.t(), non_neg_integer(), String.t()) ::
          :applied | :stale | :agent_not_found
  def apply_relationship(owner_id, peer_id, level, sequence, event_ref) do
    params = [owner_id, peer_id, level, sequence, event_ref]
    [row] = Repo.call!("relay_fn.agent_relationship_apply", params)
    Repo.code!(row["result"], [:applied, :stale, :agent_not_found])
  end

  # AG-61
  @doc "Blocks a sender for an agent, or lifts the block."
  @spec set_block(id(), id(), boolean(), String.t()) ::
          {:blocked | :lifted | :unchanged | :sender_not_found, map()}
  def set_block(owner_id, sender_id, blocked, actor_ref) do
    [row] = Repo.call!("relay_fn.agent_block_set", [owner_id, sender_id, blocked, actor_ref])
    {Repo.code!(row["result"], [:blocked, :lifted, :unchanged, :sender_not_found]), row}
  end

  # AG-61
  @doc "Records an abuse report of a message and writes `mailbox.abuse_reported` to the outbox."
  @spec report_abuse(id(), id(), id(), String.t(), String.t() | nil) ::
          {:reported | :already_reported | :not_found, DateTime.t() | nil, boolean() | nil}
  def report_abuse(id, reporter_id, record_id, sender_ref, statement) do
    params = [id, reporter_id, record_id, sender_ref, statement]
    [row] = Repo.call!("relay_fn.mailbox_abuse_report", params)

    {Repo.code!(row["result"], [:reported, :already_reported, :not_found]), row["reported_at"],
     row["statement_attached"]}
  end

  # AG-59
  # AG-69
  @doc "How a sender stands with a recipient: the relationship level, whether the recipient blocked the sender, and the sender's first contacts of the last hour and their distinct recipients of the last day."
  @spec standing(id(), id()) :: map()
  def standing(recipient_id, sender_id) do
    sql = """
    SELECT
      (SELECT r.level FROM relay.agent_relationships r
        WHERE r.owner_agent_id = $1 AND r.peer_agent_id = $2) AS level,
      EXISTS (SELECT 1 FROM relay.agent_blocks b
        WHERE b.owner_agent_id = $1 AND b.sender_agent_id = $2 AND b.state = 'blocked')
        AS blocked,
      (SELECT count(*) FROM relay.agent_messages m
        WHERE m.sender_agent_id = $2 AND m.first_contact
          AND m.created_at > now() - interval '1 hour') AS messages_last_hour,
      (SELECT count(DISTINCT m.recipient_agent_id) FROM relay.agent_messages m
        WHERE m.sender_agent_id = $2 AND m.first_contact
          AND m.created_at > now() - interval '1 day') AS recipients_last_day
    """

    [row] = all(sql, [recipient_id, sender_id])

    %{
      relationship: level(row["level"]),
      blocked: row["blocked"],
      messages_last_hour: row["messages_last_hour"],
      recipients_last_day: row["recipients_last_day"]
    }
  end

  defp level(nil), do: :unknown
  defp level(text), do: Repo.code!(text, @levels)

  # AG-67
  @doc "Reads the metadata of a message by its record identifier, or `nil`."
  @spec message(id()) :: map() | nil
  def message(record_id) do
    sql = "SELECT #{@message_columns} FROM relay.agent_messages m WHERE m.record_id = $1"
    sql |> all([record_id]) |> List.first()
  end

  # AG-56
  # AG-67
  @doc "Reads a message of a recipient with the stored envelope, sealed, or `nil`."
  @spec envelope(id(), id()) :: map() | nil
  def envelope(recipient_id, record_id) do
    sql = """
    SELECT #{@message_columns}, r.epoch, r.seq, r.kind, r.payload_ct, r.payload_tenant_key_id,
      r.payload_erased_at
    FROM relay.agent_messages m
    JOIN relay.mailbox_records r ON r.id = m.record_id AND r.created_at = m.record_created_at
    WHERE m.record_id = $1 AND m.recipient_agent_id = $2
    """

    sql |> all([record_id, recipient_id]) |> List.first()
  end

  # AG-59
  # API-56
  @doc "A page of the request box of a recipient, newest first; at most `limit + 1`."
  @spec requests(id(), map() | nil, pos_integer()) :: [map()]
  def requests(recipient_id, cursor, limit) do
    {condition, order, params} = keyset(cursor, [recipient_id])

    sql = """
    SELECT #{@message_columns}, r.epoch, r.seq, r.kind
    FROM relay.agent_messages m
    JOIN relay.mailbox_records r ON r.id = m.record_id AND r.created_at = m.record_created_at
    WHERE m.recipient_agent_id = $1 AND m.box = 'requests'#{condition}
    ORDER BY m.record_id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "DESC", do: rows, else: Enum.reverse(rows)
  end

  defp keyset(nil, params), do: {"", "DESC", params}

  defp keyset(%{direction: :after, id: id}, params),
    do: {" AND m.record_id < $2", "DESC", params ++ [id]}

  defp keyset(%{direction: :before, id: id}, params),
    do: {" AND m.record_id > $2", "ASC", params ++ [id]}

  defp all(sql, params) do
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
