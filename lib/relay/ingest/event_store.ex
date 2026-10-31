defmodule Relay.Ingest.EventStore do
  @moduledoc """
  Data access of events: acceptance, notifications of an event, cancellation and tombstones, quotas, CloudEvents type mappings, the send mode settings and the query reads of events, notifications and deliveries. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @status """
  CASE WHEN d.failure_kind = 'skipped' THEN 'skipped'
    WHEN d.failure_kind = 'cancelled' THEN 'cancelled'
    WHEN d.failure_kind = 'expired' THEN 'expired'
    WHEN d.failure_kind IN ('failed', 'bounced') THEN 'failed'
    WHEN d.delivery_rank = 2 THEN 'delivered'
    WHEN d.delivery_rank = 1 THEN 'sent'
    ELSE 'queued' END
  """

  @notification """
  SELECT n.id, n.event_id, n.recipient_id, r.kind AS recipient_kind, n.subtenant_id,
    n.message_class, n.security_subtype, n.sender_type, n.dedup_key, n.state, n.close_rule_id,
    n.expires_at, n.duplicate_count, n.is_test, n.created_at, n.updated_at, w.key AS workflow_key,
    v.version_no AS workflow_version,
    (SELECT jsonb_object_agg(s.status, s.n) FROM (
      SELECT #{@status} AS status, count(*) AS n FROM relay.deliveries d
      WHERE d.tenant_id = n.tenant_id AND d.environment = n.environment
        AND d.notification_id = n.id
      GROUP BY 1) s) AS delivery_counts
  FROM relay.notifications n
  JOIN relay.recipients r ON r.tenant_id = n.tenant_id AND r.environment = n.environment
    AND r.id = n.recipient_id
  JOIN relay.workflows w ON w.tenant_id = n.tenant_id AND w.environment = n.environment
    AND w.id = n.workflow_id
  JOIN relay.workflow_versions v ON v.tenant_id = n.tenant_id AND v.environment = n.environment
    AND v.id = n.workflow_version_id
  """

  @delivery """
  SELECT d.id, d.notification_id, d.channel, #{@status} AS status, d.failure_rule_id,
    d.failure_reason, d.failure_class, d.failure_kind, d.decision, d.decision_rule_id,
    d.decision_reason, d.deferred_until, d.fallback_of, d.accepted_at, d.delivered_at,
    d.paused_at, d.pause_rule_id, d.created_at, d.updated_at
  FROM relay.deliveries d
  """

  @type digest :: <<_::256>>

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # API-34
  @doc "Runs `fun` in a savepoint of the current transaction: `{:error, reason}` rolls back only the savepoint."
  @spec savepoint((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def savepoint(fun) do
    Repo.scoped_query!("SAVEPOINT relay_row", [])

    try do
      fun.()
    rescue
      error ->
        Repo.scoped_query!("ROLLBACK TO SAVEPOINT relay_row", [])
        reraise error, __STACKTRACE__
    else
      {:ok, _value} = ok ->
        Repo.scoped_query!("RELEASE SAVEPOINT relay_row", [])
        ok

      {:error, _reason} = error ->
        Repo.scoped_query!("ROLLBACK TO SAVEPOINT relay_row", [])
        error
    end
  end

  # API-58
  # INV-60
  @doc "Takes the shared lock of a cancellation key for the rest of the transaction; `cancel_by_key` takes it exclusively."
  @spec cancellation_lock(String.t()) :: :ok
  def cancellation_lock(lock) do
    Repo.scoped_query!("SELECT pg_advisory_xact_lock_shared(hashtextextended($1, 0))", [lock])
    :ok
  end

  # API-51
  # TN-52
  @doc "Consumes quota for `count` accepted notifications of a class; one row per active period policy."
  @spec quota_consume(String.t(), pos_integer(), 0..15) :: [map()]
  def quota_consume(message_class, count, shard) do
    for row <- Repo.call!("relay_fn.quota_consume", [message_class, count, shard]) do
      Map.put(
        row,
        "result",
        Repo.code!(row["result"], [:allowed, :reserve, :exhausted, :class_cap, :no_policy])
      )
    end
  end

  # API-51
  # TN-52
  @doc "Sets, changes or removes (`limit_total: nil`) a quota policy of a period."
  @spec quota_policy_set(map(), digest(), Actor.t()) ::
          {atom(), pos_integer() | nil, boolean()}
  def quota_policy_set(policy, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.quota_policy_set",
        [
          policy.period,
          policy.limit_total,
          Map.get(policy, :class_caps, %{}),
          Map.get(policy, :security_reserve_bp, 1000),
          Map.get(policy, :expected_version),
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :created,
       :updated,
       :removed,
       :unchanged,
       :version_conflict,
       :invalid_caps
     ]), row["version"], row["relaxed"]}
  end

  @doc "The quota usage of the current period."
  @spec quota_usage(String.t()) :: map()
  def quota_usage(period) do
    [row] = Repo.call!("relay_fn.quota_usage", [period])
    row
  end

  # API-19
  # API-20
  # OP-7
  @doc "Records an accepted event with its encrypted payload."
  @spec event_accept(map()) :: {atom(), Relay.Id.t() | nil, DateTime.t() | nil}
  def event_accept(e) do
    [row] =
      Repo.call!("relay_fn.event_accept", [
        e.id,
        e.workflow_id,
        e.workflow_version_id,
        e.api_client_id,
        e.subtenant_id,
        e.source,
        e.ce_key_digest,
        e.dedup_key,
        e.cancellation_key,
        e.sender_type,
        e.priority,
        e.security_subtype,
        e.on_expire,
        e.send_at,
        e.expires_at,
        e.retention_none,
        e.send_mode,
        e.is_test,
        e.recipient_count,
        e.data_ct,
        e.metadata_ct,
        e.actor_ct,
        e.ce_attributes_ct,
        e.key_id,
        e.plain_size,
        e.traceparent
      ])

    {Repo.code!(row["result"], [
       :accepted,
       :tenant_inactive,
       :workflow_not_published,
       :version_not_current,
       :send_mode_not_allowed,
       :send_at_invalid,
       :subtenant_suspended
     ]), row["event_id"], row["created_at"]}
  end

  # API-26
  @doc "Clears the event data of a `security_subtype` or `retention: none` event once all its deliveries are terminal."
  @spec event_payload_erase(Relay.Id.t(), String.t()) :: :erased | :already_erased | :not_terminal
  def event_payload_erase(event_id, reason) do
    [row] = Repo.call!("relay_fn.event_payload_erase", [event_id, reason])
    Repo.code!(row["event_payload_erase"], [:erased, :already_erased, :not_terminal])
  end

  # API-16
  # WF-7
  @doc "Accepts the notification of one recipient of an event, frozen to the event's workflow version."
  @spec notification_accept(map()) :: {atom(), Relay.Id.t() | nil, Relay.Id.t() | nil}
  def notification_accept(n) do
    [row] =
      Repo.call!("relay_fn.notification_accept", [
        n.id,
        n.recipient_id,
        n.subtenant_id,
        n.dedup_key,
        n.message_class,
        n.security_subtype,
        n.sender_type,
        nil,
        nil,
        n.expires_at,
        n.is_test,
        n.traceparent,
        n.event_id,
        n.workflow_id,
        n.workflow_version_id
      ])

    {Repo.code!(row["result"], [
       :created,
       :duplicate,
       :recipient_not_found,
       :subtenant_not_found,
       :tenant_inactive
     ]), row["notification_id"], row["original_event_id"]}
  end

  # API-57
  # API-58
  # API-59
  @doc "Cancels the pending deliveries of an event; see the cancellation functions for the counts."
  @spec cancel_event(Relay.Id.t(), Relay.Id.t(), String.t() | nil, pos_integer(), Actor.t()) ::
          map()
  def cancel_event(id, event_id, reason, limit, %Actor{} = actor) do
    cancel("relay_fn.cancel_event", [id, event_id, reason, limit] ++ Actor.params(actor))
  end

  # API-57
  @doc "Cancels the pending deliveries of a notification."
  @spec cancel_notification(Relay.Id.t(), Relay.Id.t(), String.t() | nil, Actor.t()) :: map()
  def cancel_notification(id, notification_id, reason, %Actor{} = actor) do
    cancel("relay_fn.cancel_notification", [id, notification_id, reason] ++ Actor.params(actor))
  end

  # API-57
  # API-58
  # INV-60
  @doc "Cancels the pending deliveries of every event with a cancellation key, optionally narrowed to recipients and channels."
  @spec cancel_by_key(map(), Actor.t()) :: map()
  def cancel_by_key(c, %Actor{} = actor) do
    cancel(
      "relay_fn.cancel_by_key",
      [c.id, c.key, c.recipient_ids, c.channels, c.reason, c.limit] ++ Actor.params(actor)
    )
  end

  defp cancel(function, params) do
    [row] = Repo.call!(function, params)
    Map.put(row, "result", Repo.code!(row["result"], [:cancelled, :not_found]))
  end

  # API-58
  @doc "The tombstone that cancels a not yet started run of an event for a recipient and channel, or `nil`."
  @spec cancellation_applies(Relay.Id.t(), Relay.Id.t(), String.t()) :: Relay.Id.t() | nil
  def cancellation_applies(event_id, recipient_id, channel) do
    [row] = Repo.call!("relay_fn.cancellation_applies", [event_id, recipient_id, channel])
    row["cancellation_applies"]
  end

  # API-28
  # MD-16
  @doc "Creates a CloudEvents type mapping."
  @spec mapping_create(map(), digest(), Actor.t()) :: {atom(), Relay.Id.t() | nil, term()}
  def mapping_create(m, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.event_type_mapping_create",
        [
          m.id,
          m.type,
          m.source,
          m.workflow,
          m.to_pointer,
          m.tenant_pointer,
          m.data_fields,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:created, :conflict, :workflow_not_found]), row["mapping_id"],
     row["version"]}
  end

  # API-28
  @doc "Replaces a CloudEvents type mapping."
  @spec mapping_replace(map(), pos_integer() | nil, digest(), Actor.t()) :: {atom(), term()}
  def mapping_replace(m, expected_version, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.event_type_mapping_replace",
        [
          m.id,
          m.type,
          m.source,
          m.workflow,
          m.to_pointer,
          m.tenant_pointer,
          m.data_fields,
          expected_version,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :replaced,
       :unchanged,
       :conflict,
       :version_conflict,
       :not_found,
       :archived,
       :workflow_not_found
     ]), row["version"]}
  end

  # API-28
  @doc "Archives a CloudEvents type mapping."
  @spec mapping_archive(Relay.Id.t(), pos_integer() | nil, digest(), Actor.t()) ::
          {atom(), term()}
  def mapping_archive(id, expected_version, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.event_type_mapping_archive",
        [id, expected_version, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:archived, :already_archived, :version_conflict, :not_found]),
     row["version"]}
  end

  # API-29
  @doc "Resolves the active mapping of a CloudEvents type and source: the exact source first, then a mapping for any source."
  @spec mapping_resolve(String.t(), String.t()) :: map() | nil
  def mapping_resolve(type, source) do
    case Repo.call!("relay_fn.event_type_mapping_resolve", [type, source]) do
      [row] -> row
      [] -> nil
    end
  end

  @mapping """
  SELECT m.id, m.type, m.source, w.key AS workflow, m.to_pointer, m.tenant_pointer,
    m.data_fields, m.state, m.version, m.created_at, m.updated_at
  FROM relay.event_type_mappings m
  JOIN relay.workflows w ON w.tenant_id = m.tenant_id AND w.environment = m.environment
    AND w.id = m.workflow_id
  """

  @doc "Reads a CloudEvents type mapping, or `nil`."
  @spec mapping(Relay.Id.t()) :: map() | nil
  def mapping(id), do: one(@mapping <> " WHERE m.id = $1", [id])

  # API-56
  @doc "Lists CloudEvents type mappings newest first; at most `limit + 1` rows."
  @spec mappings(map() | nil, pos_integer()) :: [map()]
  def mappings(cursor, limit), do: page(@mapping, "m", "TRUE", [], cursor, limit)

  # OP-51
  @doc "Resolves stored settings of the tenant by key."
  @spec settings([String.t()]) :: %{String.t() => term()}
  def settings(keys) do
    for row <- Repo.call!("relay_fn.setting_resolve", [nil, keys]),
        row["value"] != nil,
        into: %{},
        do: {row["key"], row["value"]}
  end

  @doc "Reads an event with its workflow reference and the notifications it accepted, or `nil`."
  @spec event(Relay.Id.t()) :: map() | nil
  def event(id) do
    case one(
           """
           SELECT e.id, e.source, e.subtenant_id, e.dedup_key, e.cancellation_key, e.send_at,
             e.expires_at, e.priority, e.recipient_count, e.state, e.is_test, e.created_at,
             e.cancelled_at, e.payload_created_at, w.key AS workflow_key,
             v.version_no AS workflow_version
           FROM relay.events e
           JOIN relay.workflows w ON w.tenant_id = e.tenant_id AND w.environment = e.environment
             AND w.id = e.workflow_id
           JOIN relay.workflow_versions v ON v.tenant_id = e.tenant_id
             AND v.environment = e.environment AND v.id = e.workflow_version_id
           WHERE e.id = $1
           """,
           [id]
         ) do
      nil ->
        nil

      event ->
        notifications =
          maps(
            Repo.scoped_query!(
              """
              SELECT n.id, n.recipient_id, r.kind AS recipient_kind FROM relay.notifications n
              JOIN relay.recipients r ON r.tenant_id = n.tenant_id
                AND r.environment = n.environment AND r.id = n.recipient_id
              WHERE n.event_id = $1 ORDER BY n.created_at, n.id
              """,
              [id]
            )
          )

        payload =
          one(
            """
            SELECT p.metadata_ct, p.actor_ct, p.ce_attributes_ct, p.key_id
            FROM relay.event_payloads p WHERE p.event_id = $1 AND p.created_at = $2
            """,
            [id, event["payload_created_at"]]
          )

        Map.merge(event, %{"notifications" => notifications, "payload" => payload})
    end
  end

  @doc "Reads a notification of an event with its workflow reference and delivery counts, or `nil`."
  @spec notification(Relay.Id.t()) :: map() | nil
  def notification(id), do: one(@notification <> " WHERE n.id = $1", [id])

  # API-56
  @doc "Lists notifications of events newest first under filters; at most `limit + 1` rows."
  @spec notifications(map(), map() | nil, pos_integer()) :: [map()]
  def notifications(filters, cursor, limit) do
    {where, params} =
      Enum.reduce(filters, {"n.event_id IS NOT NULL", []}, fn
        {:recipient_ids, ids}, {sql, ps} ->
          {sql <> " AND n.recipient_id = ANY ($#{length(ps) + 1})", ps ++ [ids]}

        {:workflow, key}, {sql, ps} ->
          {sql <> " AND w.key = $#{length(ps) + 1}", ps ++ [key]}

        {:status, status}, {sql, ps} ->
          exists =
            " AND EXISTS (SELECT 1 FROM relay.deliveries d WHERE d.tenant_id = n.tenant_id" <>
              " AND d.environment = n.environment AND d.notification_id = n.id" <>
              " AND (#{@status}) = $#{length(ps) + 1})"

          {sql <> exists, ps ++ [status]}

        {:created_after, at}, {sql, ps} ->
          {sql <> " AND n.created_at >= $#{length(ps) + 1}", ps ++ [at]}

        {:created_before, at}, {sql, ps} ->
          {sql <> " AND n.created_at < $#{length(ps) + 1}", ps ++ [at]}
      end)

    page(@notification, "n", where, params, cursor, limit)
  end

  @doc "Reads a delivery, or `nil`."
  @spec delivery(Relay.Id.t()) :: map() | nil
  def delivery(id), do: one(@delivery <> " WHERE d.id = $1", [id])

  # API-56
  @doc "Lists the deliveries of a notification newest first; at most `limit + 1` rows."
  @spec deliveries(Relay.Id.t(), map() | nil, pos_integer()) :: [map()]
  def deliveries(notification_id, cursor, limit),
    do: page(@delivery, "d", "d.notification_id = $1", [notification_id], cursor, limit)

  @doc "Reads the attempts of a delivery in attempt order."
  @spec attempts(Relay.Id.t()) :: [map()]
  def attempts(delivery_id) do
    maps(
      Repo.scoped_query!(
        """
        SELECT a.id, a.attempt_no, a.state, a.provider, a.failure_class, a.raw_code,
          a.started_at, a.finished_at
        FROM relay.delivery_attempts a WHERE a.delivery_id = $1 ORDER BY a.attempt_no
        """,
        [delivery_id]
      )
    )
  end

  @doc "Reads the ledger events of a delivery in arrival order."
  @spec ledger(Relay.Id.t()) :: [map()]
  def ledger(delivery_id) do
    maps(
      Repo.scoped_query!(
        """
        SELECT e.id, e.actor, e.event_type, e.attempt_no, e.raw_code, e.provider, e.occurred_at,
          e.received_at
        FROM relay.delivery_events e WHERE e.delivery_id = $1 ORDER BY e.received_at, e.id
        """,
        [delivery_id]
      )
    )
  end

  defp page(base, alias_, where, params, cursor, limit) do
    {condition, order, params} =
      case cursor do
        nil ->
          {"", "DESC", params}

        %{direction: direction, sort_ts_us: ts, id: id} ->
          n = length(params)
          op = if direction == :after, do: "<", else: ">"
          order = if direction == :after, do: "DESC", else: "ASC"

          {" AND (#{alias_}.created_at, #{alias_}.id) #{op} ($#{n + 1}, $#{n + 2})", order,
           params ++ [DateTime.from_unix!(ts, :microsecond), id]}
      end

    sql =
      base <>
        " WHERE #{where}#{condition}" <>
        " ORDER BY #{alias_}.created_at #{order}, #{alias_}.id #{order} LIMIT #{limit + 1}"

    rows = maps(Repo.scoped_query!(sql, params))
    if order == "ASC", do: Enum.reverse(rows), else: rows
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
