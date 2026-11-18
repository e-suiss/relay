defmodule Relay.Webhooks.EngineStore do
  @moduledoc """
  Data access of the delivery engine: events, messages, attempts and endpoint health. Rows are written only through the `relay_fn.webhook_*` engine functions, which take the time of the caller's clock, and are never deleted. Every function but `due_scopes/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type id :: Relay.Id.t()

  @claimed ~w(claimed not_found locked terminal tenant_inactive endpoint_archived
              endpoint_paused endpoint_disabled expired window_exceeded held not_due)a
  @parked ~w(parked not_found lock_lost)a
  @settled ~w(settled lock_lost not_found)a
  @saved ~w(saved not_found)a
  @changed ~w(changed unchanged not_found archived managed invalid_state)a

  @message_columns "m.id, m.endpoint_id, m.event_id, m.endpoint_version, m.event_type, m.origin, m.state, m.hold_reason, m.reason, m.schedule_no, m.schedule_started_at, m.attempt_count, m.total_attempt_count, m.retry_after_count, m.next_attempt_at, m.window_ends_at, m.expires_at, m.locked_until, m.last_attempt_at, m.last_response_status, m.delivered_at, m.terminal_at, m.created_at, m.updated_at"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "The scope of the caller's transaction."
  @spec current_scope() :: Relay.Scope.t() | nil
  def current_scope, do: Repo.current_scope()

  @doc "Rolls the caller's transaction back with `value`."
  @spec rollback(term()) :: no_return()
  def rollback(value), do: Repo.rollback(value)

  # WH-16
  # WH-34 (2)
  # WH-67
  # OP-52 (1)
  # OP-94
  @doc "The endpoints of use `relay_events` that are not archived and subscribe to `event_type` or, when `wildcard` is true, to `*`, with their retry schedule: the shadow endpoints when `shadow` is true, the live ones otherwise."
  @spec subscribers(String.t(), boolean(), boolean()) :: [map()]
  def subscribers(event_type, wildcard, shadow \\ false)
      when is_boolean(wildcard) and is_boolean(shadow) do
    all(
      """
      SELECT e.id, e.state, e.retry_schedule FROM relay.webhook_endpoints e
      WHERE e.use_kind = 'relay_events' AND e.state <> 'archived' AND e.shadow = $3
        AND (e.event_types @> ARRAY[$1::text] OR ($2 AND e.event_types @> ARRAY['*'::text]))
      ORDER BY e.id
      """,
      [event_type, wildcard, shadow]
    )
  end

  # OP-52 (1)
  # OP-94
  @doc "What tells whether an event about a delivery comes from a shadow send: the delivery's channel, its event's requested send mode, its workflow's key and category and the provider of its latest attempt; `nil` when there is no such delivery."
  @spec delivery_mode(id()) :: map() | nil
  def delivery_mode(delivery_id) do
    one(
      """
      SELECT d.tenant_id, d.environment, d.channel::text AS channel,
        e.send_mode::text AS send_mode, wf.key AS workflow_key,
        wv.definition->>'category' AS category,
        (SELECT a.provider FROM relay.delivery_attempts a WHERE a.tenant_id = d.tenant_id
          AND a.environment = d.environment AND a.delivery_id = d.id
          ORDER BY a.attempt_no DESC LIMIT 1) AS provider
      FROM relay.deliveries d
      JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
        AND n.id = d.notification_id
      LEFT JOIN relay.events e ON e.tenant_id = n.tenant_id AND e.environment = n.environment
        AND e.id = n.event_id
      LEFT JOIN relay.workflow_versions wv ON wv.tenant_id = e.tenant_id
        AND wv.environment = e.environment AND wv.id = e.workflow_version_id
      LEFT JOIN relay.workflows wf ON wf.tenant_id = e.tenant_id
        AND wf.environment = e.environment AND wf.id = e.workflow_id
      WHERE d.id = $1
      """,
      [delivery_id]
    )
  end

  # WH-2
  # INV-12
  @doc "Records an event (`event`, `nil` for an event that already exists) and creates one message for each endpoint that has none for it; returns the messages it created with their state."
  @spec fan_out(id(), map() | nil, map() | nil, binary() | nil, [map()], map(), DateTime.t()) ::
          [map()]
  def fan_out(event_id, event, payload, digest, messages, opts, %DateTime{} = now) do
    Repo.call!("relay_fn.webhook_fan_out", [
      event_id,
      event,
      payload,
      digest,
      Enum.map(messages, & &1.id),
      Enum.map(messages, & &1.endpoint_id),
      Enum.map(messages, & &1.next_attempt_at),
      Enum.map(messages, & &1.window_ends_at),
      Map.get(opts, :expires_at),
      Map.fetch!(opts, :origin),
      Map.get(opts, :reason),
      now
    ])
  end

  # WH-2
  @doc "Reads a message, or `nil`."
  @spec message(id()) :: map() | nil
  def message(id) do
    one("SELECT #{@message_columns} FROM relay.webhook_messages m WHERE m.id = $1", [id])
  end

  # WH-2
  @doc "Reads the message of an event on an endpoint, or `nil`."
  @spec message_of(id(), id()) :: map() | nil
  def message_of(endpoint_id, event_id) do
    where = "m.endpoint_id = $1 AND m.event_id = $2"
    sql = "SELECT #{@message_columns} FROM relay.webhook_messages m WHERE #{where}"
    one(sql, [endpoint_id, event_id])
  end

  # WH-8
  # WH-12
  @doc "Reads what an attempt of a message needs: its event, its endpoint and the snapshot allow-list of the endpoint version the message is pinned to; `nil` for an unknown message."
  @spec delivery(id()) :: map() | nil
  def delivery(message_id) do
    case message(message_id) do
      nil ->
        nil

      message ->
        %{
          message: message,
          event: event(message["event_id"]),
          endpoint: endpoint(message["endpoint_id"]),
          version: endpoint_version(message["endpoint_id"], message["endpoint_version"])
        }
    end
  end

  @doc "Reads an event, or `nil`."
  @spec event(id()) :: map() | nil
  def event(id) do
    case events([id]) do
      [event] -> event
      [] -> nil
    end
  end

  # WH-21
  @doc "Reads the events of `ids`."
  @spec events([id()]) :: [map()]
  def events(ids) do
    all(
      """
      SELECT e.id, e.use_kind, e.event_type, e.schema_version, e.origin, e.source, e.subject,
        e.seq, e.occurred_at, e.traceparent, e.payload, e.payload_erased_at, e.created_at
      FROM relay.webhook_events e WHERE e.id = ANY($1::uuid[])
      """,
      [ids]
    )
  end

  # WH-21
  @doc "Reads the messages of `ids`."
  @spec messages([id()]) :: [map()]
  def messages(ids) do
    sql = "SELECT #{@message_columns} FROM relay.webhook_messages m WHERE m.id = ANY($1::uuid[])"
    all(sql, [ids])
  end

  @doc "Reads the engine's view of an endpoint, or `nil`."
  @spec endpoint(id()) :: map() | nil
  def endpoint(id) do
    one(
      """
      SELECT e.id, e.use_kind, e.kind, e.url, e.destination, e.credential_ref_id, e.state,
        e.disabled_reason, e.auto_disable, e.retry_schedule, e.max_concurrency,
        e.rate_per_second, e.managed_by, e.version
      FROM relay.webhook_endpoints e WHERE e.id = $1
      """,
      [id]
    )
  end

  # WH-12
  @doc "Reads the snapshot allow-list and the payload version of an endpoint version, or `nil`."
  @spec endpoint_version(id(), pos_integer()) :: map() | nil
  def endpoint_version(endpoint_id, version) do
    one(
      """
      SELECT v.snapshot, v.payload_version FROM relay.webhook_endpoint_versions v
      WHERE v.endpoint_id = $1 AND v.version = $2
      """,
      [endpoint_id, version]
    )
  end

  # E-85
  @doc "The envelope context of the scope: the bound Access tenant, the Access organization of a sub-tenant and the correlation identifier of a notification's event; both identifiers may be `nil`."
  @spec envelope_context(id() | nil, id() | nil) :: map()
  def envelope_context(subtenant_id, notification_id) do
    one(
      """
      SELECT
        (SELECT t.access_tenant_id FROM relay.tenants t
          WHERE t.id = relay_private.ctx_tenant_id()) AS access_tenant_id,
        (SELECT s.access_organization_id FROM relay.subtenants s WHERE s.id = $1)
          AS access_organization_id,
        (SELECT e.correlation_id FROM relay.notifications n
          JOIN relay.events e ON e.tenant_id = n.tenant_id AND e.environment = n.environment
            AND e.id = n.event_id
          WHERE n.id = $2) AS correlation_id
      """,
      [subtenant_id, notification_id]
    )
  end

  # WH-32 (4)
  @doc "Claims a message for one attempt until `locked_until`; a manual claim locks the message without changing its state. Returns the result and, for `:not_due` and `:locked`, the time to come back."
  @spec claim(id(), id(), DateTime.t(), boolean(), DateTime.t()) :: {atom(), DateTime.t() | nil}
  def claim(message_id, token, locked_until, manual?, now) do
    params = [message_id, token, locked_until, manual?, now]
    [row] = Repo.call!("relay_fn.webhook_message_claim", params)

    {Repo.code!(row["result"], @claimed), row["next_attempt_at"]}
  end

  # WH-38
  @doc "Gives a claimed message back without an attempt: to `state` (`pending`, `scheduled` or `held`), or with `nil` only its lock."
  @spec park(id(), id(), String.t() | nil, String.t() | nil, DateTime.t() | nil, DateTime.t()) ::
          atom()
  def park(message_id, token, state, hold_reason, next_attempt_at, now) do
    params = [message_id, token, state, hold_reason, next_attempt_at, now]
    [row] = Repo.call!("relay_fn.webhook_message_park", params)
    Repo.code!(row["webhook_message_park"], @parked)
  end

  # WH-35
  @doc "Reads the health row of an endpoint and locks it until the transaction ends, or `nil`."
  @spec health_lock(id()) :: map() | nil
  def health_lock(endpoint_id) do
    case Repo.call!("relay_fn.webhook_endpoint_health_lock", [endpoint_id]) do
      [row] -> row
      [] -> nil
    end
  end

  # WH-35
  # WH-36
  @doc "Reads the health row of an endpoint, or `nil`."
  @spec health(id()) :: map() | nil
  def health(endpoint_id) do
    one("SELECT h.* FROM relay.webhook_endpoint_health h WHERE h.endpoint_id = $1", [endpoint_id])
  end

  # WH-35
  # WH-36
  @doc "Writes the health columns of an endpoint from `health`, a map of every health column."
  @spec health_save(id(), map(), DateTime.t()) :: atom()
  def health_save(endpoint_id, health, now) do
    [row] = Repo.call!("relay_fn.webhook_endpoint_health_save", [endpoint_id, health, now])
    Repo.code!(row["webhook_endpoint_health_save"], @saved)
  end

  # WH-10
  @doc "Appends the attempt log row of a claimed message and moves the message to `message`, a map of its new state, or with `nil` leaves its state as it is. Returns the result and the attempt number."
  @spec settle(id(), id(), map(), binary(), map() | nil, map() | nil, DateTime.t()) ::
          {atom(), pos_integer() | nil}
  def settle(message_id, token, attempt, body_digest, sealed, message, now) do
    sealed = sealed || %{}

    [row] =
      Repo.call!("relay_fn.webhook_attempt_settle", [
        message_id,
        token,
        Relay.Id.generate(),
        attempt,
        body_digest,
        Map.get(sealed, :ct),
        Map.get(sealed, :key_id),
        message,
        now
      ])

    {Repo.code!(row["result"], @settled), row["attempt_no"]}
  end

  # WH-27
  @doc "Moves messages that are neither terminal nor locked to a terminal state; returns the moved ones."
  @spec terminate([id()], String.t(), String.t(), String.t() | nil, DateTime.t()) :: [map()]
  def terminate(ids, state, reason, actor_ref, now),
    do: Repo.call!("relay_fn.webhook_messages_terminate", [ids, state, reason, actor_ref, now])

  # WH-31
  # WH-32
  @doc "Queues messages again: `release` gives held messages their next attempt time, `rescue` does so for messages whose lock ran out, and `restart` starts the schedule of any message that is not delivered from the beginning. `entries` hold `:id`, `:next_attempt_at` and, for a restart, `:window_ends_at`. Returns the messages it changed."
  @spec requeue([map()], String.t(), DateTime.t()) :: [map()]
  def requeue(entries, mode, now) do
    Repo.call!("relay_fn.webhook_messages_requeue", [
      Enum.map(entries, & &1.id),
      Enum.map(entries, & &1.next_attempt_at),
      Enum.map(entries, &Map.get(&1, :window_ends_at)),
      mode,
      now
    ])
  end

  # WH-31
  # WH-36
  @doc "Pauses, resumes or disables an endpoint; `reason` is `failing` or `gone` for a disable. Returns the result and the endpoint's row version."
  @spec endpoint_set_state(
          id(),
          String.t(),
          String.t() | nil,
          binary(),
          Actor.t(),
          DateTime.t()
        ) :: {atom(), pos_integer() | nil}
  def endpoint_set_state(id, state, reason, digest, %Actor{} = actor, now) do
    params = [id, state, reason, digest] ++ Actor.params(actor) ++ [now]
    [row] = Repo.call!("relay_fn.webhook_endpoint_set_state", params)
    {Repo.code!(row["result"], @changed), row["version"]}
  end

  # WH-34
  @doc "Appends an operational event of an endpoint to the outbox."
  @spec outbox_append(String.t(), id(), map()) :: :appended
  def outbox_append(event_type, endpoint_id, payload) do
    stream = "webhook_endpoint:" <> Relay.Id.to_string(endpoint_id)
    params = [Relay.Id.generate(), event_type, stream, payload, nil]
    [row] = Repo.call!("relay_fn.outbox_append", params)
    Repo.code!(row["result"], [:appended])
  end

  # WH-31
  @doc "The held messages of an endpoint with `hold_reason`, oldest first, at most `limit`."
  @spec held(id(), String.t(), pos_integer()) :: [map()]
  def held(endpoint_id, hold_reason, limit) do
    all(
      """
      SELECT m.id, m.attempt_count FROM relay.webhook_messages m
      WHERE m.endpoint_id = $1 AND m.state = 'held' AND m.hold_reason = $2
      ORDER BY m.id LIMIT $3
      """,
      [endpoint_id, hold_reason, limit]
    )
  end

  # WH-28
  # WH-32 (4)
  @doc "The messages of the scope the sweep acts on at `now`: those whose lock ran out (`rescue`), those due since `overdue` without having started (`overdue`), and those waiting behind an open breaker past their window or held past their delivery time (`ended`). A message that waits in a batch is left to its batch (WH-21)."
  @spec due(DateTime.t(), DateTime.t(), pos_integer()) :: [map()]
  def due(now, overdue, limit) do
    all(
      """
      SELECT m.id, m.endpoint_id, m.state, m.hold_reason, m.attempt_count,
        CASE
          WHEN m.state = 'in_flight' THEN 'rescue'
          WHEN m.state = 'held' AND m.expires_at <= $1 THEN 'expired'
          WHEN m.state = 'held' THEN 'window_exceeded'
          ELSE 'overdue' END AS action
      FROM relay.webhook_messages m
      WHERE m.terminal_at IS NULL
        AND ((m.state = 'in_flight' AND m.locked_until <= $1)
          OR (m.state IN ('pending', 'scheduled') AND m.next_attempt_at <= $2)
          OR (m.state = 'held' AND m.expires_at <= $1)
          OR (m.state = 'held' AND m.hold_reason = 'breaker_open' AND m.window_ends_at <= $1))
        AND NOT EXISTS (SELECT 1 FROM relay.webhook_batches b
          WHERE b.tenant_id = m.tenant_id AND b.environment = m.environment
            AND b.id = m.batch_id AND b.state IN ('open', 'closed'))
      ORDER BY m.id LIMIT $3
      """,
      [now, overdue, limit]
    )
  end

  # WH-28 (1)
  @doc "The age reference of the scope's backlog: the creation time of its oldest message that waits for an attempt, or `nil`."
  @spec oldest_waiting() :: DateTime.t() | nil
  def oldest_waiting do
    row =
      one(
        """
        SELECT min(m.created_at) AS oldest FROM relay.webhook_messages m
        WHERE m.state IN ('pending', 'scheduled')
        """,
        []
      )

    row["oldest"]
  end

  # WH-36
  @doc "The endpoints of the scope whose uninterrupted failure started at or before `since` and that are still active."
  @spec failing(DateTime.t()) :: [map()]
  def failing(since) do
    all(
      """
      SELECT h.endpoint_id FROM relay.webhook_endpoint_health h
      JOIN relay.webhook_endpoints e ON e.tenant_id = h.tenant_id
        AND e.environment = h.environment AND e.id = h.endpoint_id
      WHERE h.failing_clock_at IS NOT NULL AND h.failing_since <= $1 AND e.state = 'active'
      ORDER BY h.endpoint_id
      """,
      [since]
    )
  end

  # WH-39
  @doc "The attempt statistics of an endpoint since `since`: succeeded and failed attempts, the latency percentiles of the answered ones and the failure codes with their count and last time."
  @spec statistics(id(), DateTime.t()) :: %{totals: map(), failures: [map()]}
  def statistics(endpoint_id, since) do
    totals =
      one(
        """
        SELECT count(*) FILTER (WHERE a.result = 'succeeded') AS succeeded,
          count(*) FILTER (WHERE a.result <> 'succeeded') AS failed,
          (percentile_disc(0.5) WITHIN GROUP (ORDER BY a.duration_ms))::bigint AS p50,
          (percentile_disc(0.95) WITHIN GROUP (ORDER BY a.duration_ms))::bigint AS p95,
          (percentile_disc(0.99) WITHIN GROUP (ORDER BY a.duration_ms))::bigint AS p99
        FROM relay.webhook_attempts a
        WHERE a.endpoint_id = $1 AND a.created_at >= $2 AND a.result IS NOT NULL
        """,
        [endpoint_id, since]
      )

    failures =
      all(
        """
        SELECT a.failure_code AS code, count(*) AS count, max(a.created_at) AS last_at
        FROM relay.webhook_attempts a
        WHERE a.endpoint_id = $1 AND a.created_at >= $2 AND a.failure_code IS NOT NULL
          AND a.result <> 'succeeded'
        GROUP BY a.failure_code ORDER BY max(a.created_at) DESC LIMIT 20
        """,
        [endpoint_id, since]
      )

    %{totals: totals, failures: failures}
  end

  # WH-39
  @doc "The backlog of an endpoint: its waiting and held messages and the creation time of the oldest waiting one."
  @spec backlog(id()) :: map()
  def backlog(endpoint_id) do
    one(
      """
      SELECT count(*) FILTER (WHERE m.state IN ('pending', 'scheduled', 'in_flight')) AS waiting,
        count(*) FILTER (WHERE m.state = 'held') AS held,
        min(m.created_at) FILTER (WHERE m.state IN ('pending', 'scheduled')) AS oldest_at
      FROM relay.webhook_messages m
      WHERE m.endpoint_id = $1 AND m.state IN ('pending', 'scheduled', 'in_flight', 'held')
      """,
      [endpoint_id]
    )
  end

  # WH-6
  @doc "The retired `v1a` keys of the scope whose key store objects are not destroyed yet, at most `limit`."
  @spec retired_keys(pos_integer()) :: [map()]
  def retired_keys(limit) do
    all(
      """
      SELECT k.id FROM relay.webhook_endpoint_keys k
      WHERE k.state = 'retired' AND k.scheme = 'v1a' AND k.store_destroyed_at IS NULL
      ORDER BY k.id LIMIT $1
      """,
      [limit]
    )
  end

  # WH-6
  @doc "Marks retired keys whose key store objects were destroyed; returns how many."
  @spec keys_destroyed([id()], DateTime.t()) :: non_neg_integer()
  def keys_destroyed(ids, now) do
    [row] = Repo.call!("relay_fn.webhook_endpoint_keys_destroyed", [ids, now])
    row["webhook_endpoint_keys_destroyed"]
  end

  # WH-30
  # WH-52
  @doc "Erases one batch of the answers and event payloads whose retention ended; returns how many of each."
  @spec retention_sweep(pos_integer(), pos_integer(), pos_integer(), DateTime.t()) ::
          %{responses: non_neg_integer(), payloads: non_neg_integer()}
  def retention_sweep(message_days, response_days, limit, now) do
    params = [message_days, response_days, limit, now]
    [row] = Repo.call!("relay_fn.webhook_retention_sweep", params)
    %{responses: row["responses"], payloads: row["payloads"]}
  end

  # WH-30
  @doc "The tenant's `webhook.retention` setting, or `nil` while it is unset."
  @spec retention_setting() :: map() | nil
  def retention_setting do
    case Repo.call!("relay_fn.setting_resolve", [nil, ["webhook.retention"]]) do
      [%{"value" => %{} = value}] -> value
      _unset -> nil
    end
  end

  # TN-13 (4)
  @doc "Lists the scopes that have a message the sweep acts on, through the webhook escape hatch."
  @spec due_scopes(DateTime.t(), pos_integer()) :: [{id(), String.t()}]
  def due_scopes(%DateTime{} = now, limit) when is_integer(limit) and limit > 0 do
    function = "relay_ops.webhook_due_scopes"
    rows = Repo.call_unscoped!(:webhook_due_discovery, function, [now, limit])
    for row <- rows, do: {row["tenant_id"], row["environment"]}
  end

  defp one(sql, params) do
    case all(sql, params) do
      [row] -> row
      [] -> nil
    end
  end

  defp all(sql, params) do
    %{rows: rows, columns: columns} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
