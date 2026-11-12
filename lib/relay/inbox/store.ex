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

  @doc "The scope of the caller's transaction."
  @spec current_scope() :: Relay.Scope.t() | nil
  def current_scope, do: Repo.current_scope()

  # IN-50
  # IN-14
  @doc "Marks the recipient's unread inbox items of the scope (every category or one) read up to the request's server time and stamps the announcement read mark; see `relay_fn.inbox_read_all`."
  @spec read_all(Relay.Id.t(), String.t() | nil) :: %{
          updated: non_neg_integer(),
          version: non_neg_integer(),
          notification_ids: [Relay.Id.t()],
          cut_off: DateTime.t()
        }
  def read_all(recipient_id, category) do
    [row] = Repo.call!("relay_fn.inbox_read_all", [recipient_id, category])
    :applied = Repo.code!(row["result"], [:applied])

    %{
      updated: row["updated"],
      version: row["counters_version"],
      notification_ids: row["notification_ids"] || [],
      cut_off: row["cut_off"]
    }
  end

  # IN-14
  @doc "Opens an asynchronous bulk operation; see `relay_fn.inbox_bulk_start`."
  @spec bulk_start(Relay.Id.t(), Relay.Id.t(), map()) :: DateTime.t()
  def bulk_start(id, recipient_id, attrs) do
    [row] =
      Repo.call!("relay_fn.inbox_bulk_start", [
        id,
        recipient_id,
        attrs.action,
        attrs.status,
        attrs.category,
        attrs.tag
      ])

    :created = Repo.code!(row["result"], [:created])
    row["cut_off"]
  end

  # IN-14
  @doc "Applies the next chunk of a bulk operation; see `relay_fn.inbox_bulk_chunk`."
  @spec bulk_chunk(Relay.Id.t(), pos_integer()) ::
          {:chunk | :completed | :already_completed,
           %{
             recipient_id: Relay.Id.t(),
             changed: non_neg_integer(),
             version: non_neg_integer() | nil,
             notification_ids: [Relay.Id.t()]
           }}
          | :not_found
  def bulk_chunk(operation_id, limit) do
    [row] = Repo.call!("relay_fn.inbox_bulk_chunk", [operation_id, limit])

    case Repo.code!(row["result"], [:chunk, :completed, :already_completed, :not_found]) do
      :not_found ->
        :not_found

      code ->
        {code,
         %{
           recipient_id: row["recipient_id"],
           changed: row["changed"],
           version: row["counters_version"],
           notification_ids: row["notification_ids"] || []
         }}
    end
  end

  # IN-14
  @doc "A bulk operation of a recipient, or `nil`."
  @spec bulk(Relay.Id.t(), Relay.Id.t()) :: map() | nil
  def bulk(recipient_id, operation_id) do
    sql = """
    SELECT o.tenant_id, o.environment, o.id, o.recipient_id, o.action, o.status_filter, o.category,
      o.tag, o.cut_off, o.state, o.matched_count, o.updated_count, o.chunk_count, o.created_at,
      o.updated_at, o.completed_at
    FROM relay.inbox_bulk_operations o WHERE o.recipient_id = $1 AND o.id = $2
    """

    case maps(Repo.scoped_query!(sql, [recipient_id, operation_id])) do
      [row] -> row
      [] -> nil
    end
  end

  # DS-7
  # DS-12
  @doc "Records an inbox action of the recipient on an item as engagement evidence of the item's delivery; see `relay_fn.inbox_engage`."
  @spec engage(Relay.Id.t(), Relay.Id.t(), String.t()) :: :recorded | :not_found
  def engage(recipient_id, item_id, kind) do
    [row] = Repo.call!("relay_fn.inbox_engage", [recipient_id, item_id, kind])
    Repo.code!(row["inbox_engage"], [:recorded, :not_found])
  end

  # IN-21
  @doc "Reconciles the recipient's counters with its items; see `relay_fn.inbox_reconcile`."
  @spec reconcile(Relay.Id.t()) :: {:consistent | :repaired, non_neg_integer()}
  def reconcile(recipient_id) do
    [row] = Repo.call!("relay_fn.inbox_reconcile", [recipient_id])
    {Repo.code!(row["result"], [:consistent, :repaired]), row["counters_version"]}
  end

  # IN-18
  # OP-42
  @doc "Reconciles the counters of the recipients changed since `since`, after `after` in identifier order, at most `limit`; see `relay_fn.inbox_reconcile_changed`."
  @spec reconcile_changed(DateTime.t(), Relay.Id.t() | nil, pos_integer()) :: %{
          checked: non_neg_integer(),
          repaired: non_neg_integer(),
          last: Relay.Id.t() | nil
        }
  def reconcile_changed(since, after_id, limit) do
    [row] = Repo.call!("relay_fn.inbox_reconcile_changed", [since, after_id, limit])
    :checked = Repo.code!(row["result"], [:checked])
    %{checked: row["checked"], repaired: row["repaired"], last: row["last_recipient_id"]}
  end

  # IN-44
  @doc "Takes the recipient's inbox items beyond the visible window out of the list and the counters; see `relay_fn.inbox_trim`."
  @spec trim(Relay.Id.t(), pos_integer()) :: {:trimmed | :within, non_neg_integer()}
  def trim(recipient_id, visible_max) do
    [row] = Repo.call!("relay_fn.inbox_trim", [recipient_id, visible_max])
    {Repo.code!(row["result"], [:trimmed, :within]), row["retired"]}
  end

  # IN-44
  # OP-22
  @doc "Ends the retention of due items: soft deleted and their content shredded; see `relay_fn.inbox_retire_due`."
  @spec retire_due(pos_integer(), pos_integer(), pos_integer()) :: %{
          retired: non_neg_integer(),
          recipient_ids: [Relay.Id.t()]
        }
  def retire_due(active_days, archive_days, limit) do
    [row] = Repo.call!("relay_fn.inbox_retire_due", [active_days, archive_days, limit])
    _code = Repo.code!(row["result"], [:retired, :none_due])
    %{retired: row["retired"], recipient_ids: row["recipient_ids"] || []}
  end

  # IN-44
  @doc "The tenant's `inbox.retention` setting, or `nil` while it is unset."
  @spec retention_setting() :: map() | nil
  def retention_setting do
    case Repo.call!("relay_fn.setting_resolve", [nil, ["inbox.retention"]]) do
      [%{"value" => %{} = value}] -> value
      _unset -> nil
    end
  end

  # IN-16
  # IN-35
  @doc "The recipients whose items a retraction of an event's notifications or of the given notifications reaches."
  @spec retract_recipients(Relay.Id.t() | nil, [Relay.Id.t()] | nil) :: [Relay.Id.t()]
  def retract_recipients(event_id, notification_ids) do
    sql = """
    SELECT DISTINCT x.tenant_id, x.environment, x.recipient_id
    FROM relay.notifications n
    JOIN relay.deliveries d ON d.tenant_id = n.tenant_id AND d.environment = n.environment
      AND d.notification_id = n.id
    JOIN relay.inbox_item_deliveries x ON x.tenant_id = d.tenant_id
      AND x.environment = d.environment AND x.delivery_id = d.id
    WHERE n.event_id = $1 OR n.id = ANY ($2::uuid[])
    """

    for row <- maps(Repo.scoped_query!(sql, [event_id, notification_ids || []])),
        do: row["recipient_id"]
  end

  @announcement_columns """
  a.tenant_id, a.environment, a.id, a.audience, a.category, a.tags, a.severity, a.locale, a.dir,
  a.state, a.published_at, a.expires_at, a.closed_at, a.change_seq, s.seen_at, s.read_at,
  s.unread_marked_at, s.archived_at, s.unarchived_at, s.hidden_at,
  COALESCE(s.state_version, 1) AS state_version, s.change_seq AS state_change_seq,
  (SELECT max(m.read_through) FROM relay.inbox_read_marks m
    WHERE m.recipient_id = $1 AND (m.category IS NULL OR m.category = a.category)
      AND m.read_through >= a.published_at) AS mark
  """

  @announcement_from """
  FROM relay.inbox_announcements a
  LEFT JOIN relay.inbox_announcement_states s ON s.tenant_id = a.tenant_id
    AND s.environment = a.environment AND s.announcement_id = a.id AND s.recipient_id = $1
  """

  @announcement_audience """
  (a.audience = 'tenant'
    OR (a.audience = 'topic' AND EXISTS (SELECT 1 FROM relay.topic_subscriptions t
      WHERE t.tenant_id = a.tenant_id AND t.environment = a.environment
        AND t.topic_id = a.topic_id AND t.recipient_id = $1 AND t.state = 'active'))
    OR (a.audience = 'subtenant' AND EXISTS (SELECT 1 FROM relay.inbox_items v
      WHERE v.tenant_id = a.tenant_id AND v.environment = a.environment
        AND v.recipient_id = $1 AND v.subtenant_id = a.subtenant_id)))
  """

  # IN-3
  # C-70
  @doc "The active announcements the recipient is in the audience of, merged with its own state and read mark; `content: true` also reads their content."
  @spec announcements(Relay.Id.t(), keyword()) :: [map()]
  def announcements(recipient_id, opts \\ []) do
    content = if opts[:content], do: ", a.content", else: ""

    sql = """
    SELECT #{@announcement_columns}#{content} #{@announcement_from}
    WHERE a.state = 'active' AND (a.expires_at IS NULL OR a.expires_at > clock_timestamp())
      AND #{@announcement_audience}
    ORDER BY a.published_at DESC, a.id DESC
    """

    maps(Repo.scoped_query!(sql, [recipient_id]))
  end

  # IN-3
  @doc "One announcement the recipient is in the audience of, in any state, with its content; `nil` when there is none."
  @spec announcement(Relay.Id.t(), Relay.Id.t()) :: map() | nil
  def announcement(recipient_id, announcement_id) do
    sql = """
    SELECT #{@announcement_columns}, a.content #{@announcement_from}
    WHERE a.id = $2 AND #{@announcement_audience}
    """

    case maps(Repo.scoped_query!(sql, [recipient_id, announcement_id])) do
      [row] -> row
      [] -> nil
    end
  end

  # IN-3
  # IN-29
  @doc "The announcements of the recipient's audience published, retracted or expired after the announcement sequence `since`, in sequence order, with their content; at most `limit`."
  @spec announcements_changed(Relay.Id.t(), non_neg_integer(), pos_integer()) :: [map()]
  def announcements_changed(recipient_id, since, limit) do
    sql = """
    SELECT #{@announcement_columns}, a.content #{@announcement_from}
    WHERE a.change_seq > $2 AND #{@announcement_audience}
    ORDER BY a.change_seq
    LIMIT $3
    """

    maps(Repo.scoped_query!(sql, [recipient_id, since, limit]))
  end

  # IN-3
  # IN-29
  @doc "The announcements whose state the recipient changed after `since` in `epoch` of its stream, in stream order, with their content; at most `limit`."
  @spec announcement_states_changed(
          Relay.Id.t(),
          pos_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: [map()]
  def announcement_states_changed(recipient_id, epoch, since, limit) do
    sql = """
    SELECT #{@announcement_columns}, a.content #{@announcement_from}
    WHERE s.recipient_id = $1 AND s.change_epoch = $2 AND s.change_seq > $3
    ORDER BY s.change_seq
    LIMIT $4
    """

    maps(Repo.scoped_query!(sql, [recipient_id, epoch, since, limit]))
  end

  # IN-3
  @doc "The scope's announcement sequence: it grows when an announcement is published, retracted or expires; 0 before the first."
  @spec announcement_head() :: non_neg_integer()
  def announcement_head do
    sql = "SELECT COALESCE(max(a.change_seq), 0) FROM relay.inbox_announcements a"
    %Postgrex.Result{rows: [[head]]} = Repo.scoped_query!(sql, [])
    head
  end

  # IN-3
  # API-35
  @doc "A tenant's announcement record as the server API reads it, or `nil`."
  @spec announcement_record(Relay.Id.t()) :: map() | nil
  def announcement_record(announcement_id) do
    sql = """
    SELECT a.tenant_id, a.environment, a.id, a.audience, a.subtenant_id, t.key AS topic_key,
      a.category, a.tags, a.severity, a.content, a.locale, a.dir, a.state, a.published_at,
      a.expires_at, a.closed_at, a.version
    FROM relay.inbox_announcements a
    LEFT JOIN relay.topics t ON t.tenant_id = a.tenant_id AND t.environment = a.environment
      AND t.id = a.topic_id
    WHERE a.id = $1
    """

    case maps(Repo.scoped_query!(sql, [announcement_id])) do
      [row] -> row
      [] -> nil
    end
  end

  @announcement_created [:created, :tenant_inactive, :subtenant_not_found, :topic_not_found]

  # IN-3
  # API-35
  @doc "Publishes an announcement; see `relay_fn.inbox_announcement_create`."
  @spec announcement_create(map(), binary(), Relay.Actor.t()) ::
          :created | :tenant_inactive | :subtenant_not_found | :topic_not_found
  def announcement_create(attrs, digest, actor) do
    [row] =
      Repo.call!(
        "relay_fn.inbox_announcement_create",
        [
          attrs.id,
          attrs.audience,
          attrs.subtenant_id,
          attrs.topic_key,
          attrs.category,
          attrs.tags,
          attrs.severity,
          attrs.content,
          attrs.locale,
          attrs.dir,
          attrs.expires_at,
          digest
        ] ++ Relay.Actor.params(actor)
      )

    Repo.code!(row["result"], @announcement_created)
  end

  # IN-3
  # IN-16
  @doc "Retracts an announcement; see `relay_fn.inbox_announcement_retract`."
  @spec announcement_retract(Relay.Id.t(), binary(), Relay.Actor.t()) ::
          :retracted | :already_closed | :not_found
  def announcement_retract(announcement_id, digest, actor) do
    [row] =
      Repo.call!(
        "relay_fn.inbox_announcement_retract",
        [announcement_id, digest] ++ Relay.Actor.params(actor)
      )

    Repo.code!(row["result"], [:retracted, :already_closed, :not_found])
  end

  # IN-17
  @doc "Ends a due announcement; see `relay_fn.inbox_announcement_expire`."
  @spec announcement_expire(Relay.Id.t()) :: :expired | :not_due | :already_closed | :not_found
  def announcement_expire(announcement_id) do
    [row] = Repo.call!("relay_fn.inbox_announcement_expire", [announcement_id])
    Repo.code!(row["result"], [:expired, :not_due, :already_closed, :not_found])
  end

  # IN-3
  # IN-12
  @doc "Applies one state intent of a recipient to an announcement; see `relay_fn.inbox_announcement_intent`."
  @spec announcement_intent(Relay.Id.t(), Relay.Id.t(), String.t(), integer() | nil) ::
          {:applied | :unchanged | :conflict | :invalid, pos_integer()} | :not_found
  def announcement_intent(recipient_id, announcement_id, op, base_version) do
    [row] =
      Repo.call!("relay_fn.inbox_announcement_intent", [
        recipient_id,
        announcement_id,
        op,
        base_version
      ])

    case Repo.code!(row["result"], [:applied, :unchanged, :conflict, :invalid, :not_found]) do
      :not_found -> :not_found
      code -> {code, row["state_version"]}
    end
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
