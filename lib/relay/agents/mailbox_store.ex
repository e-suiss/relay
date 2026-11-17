defmodule Relay.Agents.MailboxStore do
  @moduledoc """
  Data access for the agent face of a mailbox: the `relay_fn.mailbox_*` functions that open a mailbox, lease and acknowledge its records, and the reads of a mailbox, its position, its records and its dead letters. Every function runs inside `Relay.Repo.in_scope/3`. A held early record is the buffer of a waitpoint and is never read here.
  """

  alias Relay.Repo

  @setting "mailbox.lease"
  @mailbox_columns "m.id, m.owner_kind, m.owner_ref, m.state, m.stream_key, m.created_at"
  @record_columns "r.id, r.mailbox_id, r.epoch, r.seq, r.kind, r.event_type::text AS event_type, r.waitpoint_id, r.trust_label, r.payload_digest::bytea AS payload_digest, r.delivery_state, r.delivery_count, r.lease_until, r.acked_at, r.dead_lettered_at, r.created_at"
  @agent_face "r.kind IN ('message', 'waitpoint_event')"

  @type id :: Relay.Id.t()
  @type owner :: {:agent | :api_client, id()}
  @type cursor :: map() | nil

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # AG-64
  # AG-20
  @doc "Opens the owner's mailbox if it has none and returns its identifier."
  @spec ensure(id(), owner()) :: {:ok, id()} | :owner_not_found | :tenant_inactive
  def ensure(id, {kind, ref}) when kind in [:agent, :api_client] do
    [row] = Repo.call!("relay_fn.mailbox_ensure", [id, Atom.to_string(kind), ref])

    case Repo.code!(row["result"], [:created, :exists, :owner_not_found, :tenant_inactive]) do
      code when code in [:created, :exists] -> {:ok, row["mailbox_id"]}
      other -> other
    end
  end

  # AG-23
  @doc "Reads the mailbox of an owner, or `nil`."
  @spec by_owner(owner()) :: map() | nil
  def by_owner({kind, ref}) when kind in [:agent, :api_client] do
    sql = """
    SELECT #{@mailbox_columns} FROM relay.mailboxes m
    WHERE m.owner_kind = $1 AND m.owner_ref = $2
    """

    sql |> all([Atom.to_string(kind), ref]) |> List.first()
  end

  # AG-23
  @doc "Reads the mailbox of an agent or an API client by its identifier, or `nil`."
  @spec by_id(id()) :: map() | nil
  def by_id(mailbox_id) do
    sql = """
    SELECT #{@mailbox_columns} FROM relay.mailboxes m
    WHERE m.id = $1 AND m.owner_kind IN ('agent', 'api_client')
    """

    sql |> all([mailbox_id]) |> List.first()
  end

  # AG-24
  # IN-22
  @doc "Checks a reader position against the mailbox stream; the answer carries the current epoch and the head of the stream."
  @spec cursor_check(id(), integer(), integer()) ::
          {:ok | :resync_required, %{epoch: pos_integer(), head_seq: non_neg_integer()}}
          | :not_found
  def cursor_check(mailbox_id, epoch, since_seq) do
    [row] = Repo.call!("relay_fn.mailbox_cursor_check", [mailbox_id, epoch, since_seq])

    case Repo.code!(row["result"], [:ok, :resync_required, :not_found]) do
      :not_found -> :not_found
      code -> {code, %{epoch: row["current_epoch"], head_seq: row["head_seq"]}}
    end
  end

  # AG-20
  @doc "The lowest sequence number of an epoch that still waits for an acknowledgement, or `nil` when none does."
  @spec first_pending(id(), pos_integer()) :: pos_integer() | nil
  def first_pending(mailbox_id, epoch) do
    sql = """
    SELECT min(r.seq) AS seq FROM relay.mailbox_records r
    WHERE r.mailbox_id = $1 AND r.epoch = $2 AND r.delivery_state IN ('available', 'leased')
    """

    [%{"seq" => seq}] = all(sql, [mailbox_id, epoch])
    seq
  end

  # AG-22
  # AG-70
  @doc "The tenant's `mailbox.lease` setting, or `nil` while it is unset."
  @spec setting() :: map() | nil
  def setting do
    case Repo.call!("relay_fn.setting_resolve", [nil, [@setting]]) do
      [%{"value" => %{} = value} | _rest] -> value
      _unset -> nil
    end
  end

  # AG-20
  # AG-22
  # T-11
  # TN-8
  @doc "Leases at most `max` records that wait or whose lease ran out, in stream order; a record already delivered `max_deliveries` times is dead-lettered instead and is not returned. The lease runs on the database's business time: its clock, moved by the virtual clock in a `test` scope."
  @spec lease(id(), String.t(), pos_integer(), pos_integer(), pos_integer()) :: [map()]
  def lease(mailbox_id, holder, max, lease_ms, max_deliveries) do
    params = [mailbox_id, holder, max, lease_ms, max_deliveries]

    for row <- Repo.call!("relay_fn.mailbox_agent_lease", params) do
      row
      |> Map.put("mailbox_id", mailbox_id)
      |> Map.put("delivery_state", "leased")
      |> Map.put("acked_at", nil)
      |> Map.put("dead_lettered_at", nil)
    end
  end

  # AG-20
  @doc "Acknowledges the records a lease holds."
  @spec ack(id(), [id()], String.t()) :: [
          {id(), :acked | :already_acked | :lease_lost | :not_found}
        ]
  def ack(mailbox_id, record_ids, holder) do
    for row <- Repo.call!("relay_fn.mailbox_ack", [mailbox_id, record_ids, holder]),
        do:
          {row["record_id"],
           Repo.code!(row["result"], [:acked, :already_acked, :lease_lost, :not_found])}
  end

  # AG-24
  @doc "Reads at most `limit` records after `since_seq` of an epoch, in sequence order."
  @spec read_since(id(), pos_integer(), non_neg_integer(), pos_integer()) :: [map()]
  def read_since(mailbox_id, epoch, since_seq, limit) do
    sql = """
    SELECT #{@record_columns} FROM relay.mailbox_records r
    WHERE r.mailbox_id = $1 AND r.epoch = $2 AND r.seq > $3 AND #{@agent_face}
    ORDER BY r.seq
    LIMIT $4
    """

    all(sql, [mailbox_id, epoch, since_seq, limit])
  end

  # AG-21
  @doc "Reads one record by its identifier, or `nil`."
  @spec record(id()) :: map() | nil
  def record(record_id) do
    sql = """
    SELECT #{@record_columns} FROM relay.mailbox_records r
    WHERE r.id = $1 AND #{@agent_face}
      AND r.created_at BETWEEN uuid_extract_timestamp($1) - interval '5 minutes'
        AND uuid_extract_timestamp($1) + interval '5 minutes'
    """

    sql |> all([record_id]) |> List.first()
  end

  # AG-22
  # API-56
  @doc "A page of the dead-lettered records of a mailbox, newest first; at most `limit + 1`."
  @spec dead_letters(id(), cursor(), pos_integer()) :: [map()]
  def dead_letters(mailbox_id, cursor, limit) do
    {condition, order, params} = keyset(cursor, [mailbox_id])

    sql = """
    SELECT #{@record_columns} FROM relay.mailbox_records r
    WHERE r.mailbox_id = $1 AND r.delivery_state = 'dead_lettered'#{condition}
    ORDER BY r.id #{order}
    LIMIT #{limit + 1}
    """

    rows = all(sql, params)
    if order == "DESC", do: rows, else: Enum.reverse(rows)
  end

  defp keyset(nil, params), do: {"", "DESC", params}

  defp keyset(%{direction: :after, id: id}, params),
    do: {" AND r.id < $2", "DESC", params ++ [id]}

  defp keyset(%{direction: :before, id: id}, params),
    do: {" AND r.id > $2", "ASC", params ++ [id]}

  defp all(sql, params) do
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
