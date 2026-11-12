defmodule Relay.Inbox.Store do
  @moduledoc """
  Data access of the inbox store (IN-2): items hash partitioned by recipient, their delivery links and the recipient's counters, through the `relay_fn.inbox_*` functions for writes and tenant scoped reads for lists, items, counters and changes. Every function except `in_scope/2` runs inside the caller's `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @item_columns """
  i.tenant_id, i.environment, i.id, i.recipient_id, i.subtenant_id, i.notification_id,
  i.delivery_id, i.message_class, i.retention_class, i.category, i.tags, i.severity, i.group_key,
  i.content_ct, i.locale, i.dir, i.activity_count, i.actor_count, i.last_activity_at,
  i.expires_at, i.expired_at, i.snoozed_until, i.seen_at, i.read_at, i.unread_marked_at,
  i.archived_at, i.unarchived_at, i.hidden_at, i.hidden_reason, i.state_version, i.created_epoch,
  i.created_seq, i.change_epoch, i.change_seq, i.created_at, i.updated_at
  """

  @archived "(i.archived_at IS NOT NULL AND (i.unarchived_at IS NULL OR i.archived_at > i.unarchived_at))"
  @live "i.hidden_at IS NULL AND i.expired_at IS NULL AND (i.expires_at IS NULL OR i.expires_at > clock_timestamp())"
  @awake "(i.snoozed_until IS NULL OR i.snoozed_until <= clock_timestamp())"
  @read "(i.read_at IS NOT NULL AND i.read_at >= i.last_activity_at AND (i.unread_marked_at IS NULL OR i.read_at > i.unread_marked_at))"

  @statuses %{
    inbox: "#{@live} AND #{@awake} AND NOT #{@archived}",
    unread: "#{@live} AND #{@awake} AND NOT #{@archived} AND NOT #{@read}",
    archived: "#{@live} AND #{@archived}",
    snoozed: "#{@live} AND NOT #{@awake}",
    all: @live
  }

  @type status :: :inbox | :unread | :archived | :snoozed | :all
  @type filters :: %{
          optional(:status) => status(),
          optional(:category) => String.t(),
          optional(:tag) => String.t()
        }

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # IN-17
  # WF-43
  @doc "Queues a job inside the current transaction; rolls the transaction back when it is not queued."
  @spec insert_job!(Ecto.Changeset.t()) :: :ok
  def insert_job!(changeset) do
    case Oban.insert(changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:job_not_queued, reason})
    end
  end

  # IN-2
  # IN-5
  # WF-29
  @doc "Writes the item of an `in_app` delivery, or returns the one it already wrote; see `relay_fn.inbox_deliver`."
  @spec deliver(map()) ::
          {:created | :updated | :exists, Relay.Id.t(), Relay.Id.t(), pos_integer(),
           DateTime.t() | nil}
          | :delivery_not_found
          | :not_in_app
          | :recipient_inactive
  def deliver(attrs) do
    [row] =
      Repo.call!("relay_fn.inbox_deliver", [
        attrs.id,
        attrs.delivery_id,
        attrs.category,
        attrs.group_key,
        attrs.severity,
        attrs.tags,
        attrs.content_ct,
        attrs.content_key_id,
        attrs.content_digest,
        attrs.locale,
        attrs.dir,
        attrs.activity_count,
        attrs.actor_count
      ])

    codes = [
      :created,
      :updated,
      :exists,
      :delivery_not_found,
      :not_in_app,
      :recipient_inactive
    ]

    case Repo.code!(row["result"], codes) do
      code when code in [:created, :updated, :exists] ->
        {code, row["item_id"], row["recipient_id"], row["state_version"], row["expires_at"]}

      other ->
        other
    end
  end

  # IN-12
  @doc "Applies one state intent; see `relay_fn.inbox_intent`."
  @spec intent(Relay.Id.t(), Relay.Id.t(), String.t(), integer() | nil, DateTime.t() | nil) ::
          {:applied | :unchanged | :conflict | :invalid, pos_integer(), non_neg_integer()}
          | :not_found
  def intent(recipient_id, item_id, op, base_version, snooze_until) do
    [row] =
      Repo.call!("relay_fn.inbox_intent", [
        recipient_id,
        item_id,
        op,
        base_version,
        snooze_until
      ])

    case Repo.code!(row["result"], [:applied, :unchanged, :conflict, :invalid, :not_found]) do
      :not_found -> :not_found
      code -> {code, row["state_version"], row["counters_version"]}
    end
  end

  # IN-16
  @doc "Hides with reason `retracted` the items written by the deliveries of an event's notifications and of the given notifications; returns how many were retracted."
  @spec retract(Relay.Id.t() | nil, [Relay.Id.t()] | nil) :: non_neg_integer()
  def retract(event_id, notification_ids) do
    [row] = Repo.call!("relay_fn.inbox_retract", [event_id, notification_ids])
    :retracted = Repo.code!(row["result"], [:retracted])
    row["retracted"]
  end

  # IN-17
  @doc "Applies an item's due snooze end and expiry; returns whether anything changed and the next due time."
  @spec timer_fire(Relay.Id.t(), Relay.Id.t()) ::
          {:fired | :not_due, DateTime.t() | nil} | :not_found
  def timer_fire(recipient_id, item_id) do
    [row] = Repo.call!("relay_fn.inbox_timer_fire", [recipient_id, item_id])

    case Repo.code!(row["result"], [:fired, :not_due, :not_found]) do
      :not_found -> :not_found
      code -> {code, row["next_at"]}
    end
  end

  # IN-18
  # IN-19
  @doc "The recipient's counters; a recipient without an item has zero counters at version 0."
  @spec counters(Relay.Id.t()) :: map()
  def counters(recipient_id) do
    sql = """
    SELECT c.tenant_id, c.environment, c.unseen_count, c.unread_count, c.total_count, c.version
    FROM relay.inbox_counters c WHERE c.recipient_id = $1
    """

    case maps(Repo.scoped_query!(sql, [recipient_id])) do
      [row] ->
        %{
          unseen: row["unseen_count"],
          unread: row["unread_count"],
          total: row["total_count"],
          version: row["version"]
        }

      [] ->
        %{unseen: 0, unread: 0, total: 0, version: 0}
    end
  end

  # IN-5
  @doc "One item of a recipient, hidden or expired ones included; `nil` when there is none."
  @spec item(Relay.Id.t(), Relay.Id.t()) :: map() | nil
  def item(recipient_id, item_id) do
    sql =
      "SELECT #{@item_columns} FROM relay.inbox_items i WHERE i.recipient_id = $1 AND i.id = $2"

    case maps(Repo.scoped_query!(sql, [recipient_id, item_id])) do
      [row] -> row
      [] -> nil
    end
  end

  # IN-30
  # IN-7
  @doc "A page of a recipient's visible items, newest activity first, after the keyset position `position` (`{last_activity_at, id}` or `nil`); at most `limit` rows."
  @spec list(Relay.Id.t(), filters(), {DateTime.t(), Relay.Id.t()} | nil, pos_integer()) :: [
          map()
        ]
  def list(recipient_id, filters, position, limit) do
    status = Map.fetch!(@statuses, Map.get(filters, :status, :inbox))
    {after_sql, after_params} = after_clause(position)

    sql = """
    SELECT #{@item_columns} FROM relay.inbox_items i
    WHERE i.recipient_id = $1 AND #{status}
      AND ($2::text IS NULL OR i.category = $2)
      AND ($3::text IS NULL OR $3 = ANY (i.tags))
      #{after_sql}
    ORDER BY i.last_activity_at DESC, i.id DESC
    LIMIT $4
    """

    params = [recipient_id, filters[:category], filters[:tag], limit] ++ after_params
    maps(Repo.scoped_query!(sql, params))
  end

  defp after_clause(nil), do: {"", []}

  defp after_clause({%DateTime{} = at, <<_::128>> = id}),
    do: {"AND (i.last_activity_at, i.id) < ($5, $6)", [at, id]}

  # IN-22
  # IN-1
  @doc "The recipient's stream position: the epoch and head sequence of its mailbox stream and the replay floor; epoch 1 and sequence 0 when it has no mailbox yet."
  @spec head(Relay.Id.t()) :: %{
          epoch: pos_integer(),
          seq: non_neg_integer(),
          floor: non_neg_integer()
        }
  def head(recipient_id) do
    sql = """
    SELECT m.tenant_id, m.environment, m.replay_floor_seq,
      COALESCE(h.epoch, 1) AS epoch, COALESCE(h.last_seq, 0) AS last_seq
    FROM relay.mailboxes m
    LEFT JOIN relay.stream_heads h ON h.tenant_id = m.tenant_id
      AND h.environment = m.environment AND h.stream_key = m.stream_key
    WHERE m.owner_kind = 'subscriber' AND m.owner_ref = $1
    """

    case maps(Repo.scoped_query!(sql, [recipient_id])) do
      [row] -> %{epoch: row["epoch"], seq: row["last_seq"], floor: row["replay_floor_seq"]}
      [] -> %{epoch: 1, seq: 0, floor: 0}
    end
  end

  # IN-29
  @doc "The recipient's items changed after `since` in `epoch`, in change order; at most `limit` rows."
  @spec changed(Relay.Id.t(), pos_integer(), non_neg_integer(), pos_integer()) :: [map()]
  def changed(recipient_id, epoch, since, limit) do
    sql = """
    SELECT #{@item_columns} FROM relay.inbox_items i
    WHERE i.recipient_id = $1 AND i.change_epoch = $2 AND i.change_seq > $3
    ORDER BY i.change_seq
    LIMIT $4
    """

    maps(Repo.scoped_query!(sql, [recipient_id, epoch, since, limit]))
  end

  # IN-29
  @doc "How many of the recipient's items changed after `since` in `epoch`, counting at most `cap`."
  @spec changed_count(Relay.Id.t(), pos_integer(), non_neg_integer(), pos_integer()) ::
          non_neg_integer()
  def changed_count(recipient_id, epoch, since, cap) do
    sql = """
    SELECT count(*) FROM (SELECT 1 FROM relay.inbox_items i
      WHERE i.recipient_id = $1 AND i.change_epoch = $2 AND i.change_seq > $3 LIMIT $4) c
    """

    %Postgrex.Result{rows: [[count]]} = Repo.scoped_query!(sql, [recipient_id, epoch, since, cap])
    count
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
