defmodule Relay.Repo.Migrations.CreateObservabilityRollupFunction do
  use Ecto.Migration

  @functions [
    {"relay_ops.observability_rollup(timestamptz, timestamptz, jsonb)", "relay_maint",
     ~w(relay_worker)}
  ]

  # OP-33
  # OP-35
  # OP-36
  # DS-36
  # DS-41
  # TN-62
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_ops.observability_rollup(p_from timestamptz, p_to timestamptz,
          p_handoff_ms jsonb)
        RETURNS TABLE (kind text, label text, message_class text, channel text, provider text,
          total bigint, good bigint)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        WITH ev AS (
          SELECT e.event_type::text AS event_type, e.projection_result, e.occurred_at,
            n.message_class::text AS message_class, d.channel::text AS channel,
            coalesce(e.provider, d.provider, 'none') AS provider, d.decision_rule_id,
            d.failure_rule_id, d.created_at, d.deferred_until, d.delivered_at
          FROM relay.delivery_events e
          JOIN relay.deliveries d ON d.tenant_id = e.tenant_id
            AND d.environment = e.environment AND d.id = e.delivery_id
          JOIN relay.notifications n ON n.tenant_id = d.tenant_id
            AND n.environment = d.environment AND n.id = d.notification_id
          WHERE e.received_at > p_from AND e.received_at <= p_to
        ),
        queued AS (
          SELECT q.queue, q.tenant, sum(q.n) AS n
          FROM (
            SELECT j.queue, j.args ->> 'tenant_id' AS tenant, count(*) AS n
            FROM relay_queue.oban_jobs j
            WHERE j.state IN ('available', 'scheduled', 'retryable') AND j.args ? 'tenant_id'
            GROUP BY j.queue, j.args ->> 'tenant_id'
            UNION ALL
            SELECT w.queue, w.tenant_id::text, count(*)
            FROM relay_queue.drr_waits w
            WHERE w.state = 'waiting'
            GROUP BY w.queue, w.tenant_id
          ) q
          GROUP BY q.queue, q.tenant
        )
        SELECT 'stage'::text, 'accepted'::text, ev.message_class, ev.channel, ev.provider,
          count(*), count(*)
        FROM ev
        WHERE ev.event_type IN ('delivery.queued', 'delivery.skipped', 'delivery.deferred')
          AND ev.occurred_at BETWEEN ev.created_at - interval '5 seconds'
            AND ev.created_at + interval '5 seconds'
        GROUP BY ev.message_class, ev.channel, ev.provider
        UNION ALL
        SELECT 'stage', CASE ev.event_type
            WHEN 'delivery.queued' THEN 'enqueued'
            WHEN 'attempt.started' THEN 'dispatched'
            WHEN 'attempt.succeeded' THEN 'provider_accepted'
            ELSE 'failed'
          END, ev.message_class, ev.channel, ev.provider, count(*), count(*)
        FROM ev
        WHERE ev.event_type IN ('delivery.queued', 'attempt.started', 'attempt.succeeded',
          'attempt.failed')
        GROUP BY 2, 3, 4, 5
        UNION ALL
        SELECT 'stage', 'delivered', ev.message_class, ev.channel, ev.provider, count(*),
          count(*)
        FROM ev
        WHERE ev.event_type = 'provider.reported' AND ev.projection_result = 'applied'
          AND ev.delivered_at = ev.occurred_at
        GROUP BY ev.message_class, ev.channel, ev.provider
        UNION ALL
        SELECT 'skipped', coalesce(ev.failure_rule_id, ev.decision_rule_id, 'unknown'),
          ev.message_class, ev.channel, ev.provider, count(*), count(*)
        FROM ev
        WHERE ev.event_type = 'delivery.skipped'
        GROUP BY 2, 3, 4, 5
        UNION ALL
        SELECT 'anomaly', CASE ev.projection_result
            WHEN 'conflict_flagged' THEN 'conflict'
            ELSE 'late_event'
          END, ev.message_class, ev.channel, ev.provider, count(*), count(*)
        FROM ev
        WHERE ev.projection_result IN ('conflict_flagged', 'stale_ignored')
        GROUP BY 2, 3, 4, 5
        UNION ALL
        SELECT 'outcome', CASE ev.event_type
            WHEN 'attempt.unknown' THEN 'unknown'
            ELSE 'unknown_pending'
          END, ev.message_class, ev.channel, ev.provider, count(*), count(*)
        FROM ev
        WHERE ev.event_type IN ('attempt.unknown', 'delivery.uncertain')
        GROUP BY 2, 3, 4, 5
        UNION ALL
        SELECT 'handoff', '', ev.message_class, ev.channel, ev.provider, count(*),
          count(*) FILTER (WHERE ev.occurred_at
            - greatest(ev.created_at, coalesce(ev.deferred_until, ev.created_at))
            <= make_interval(secs => coalesce((p_handoff_ms ->> ev.message_class)::double precision,
              0) / 1000))
        FROM ev
        WHERE ev.event_type = 'attempt.succeeded'
        GROUP BY ev.message_class, ev.channel, ev.provider
        UNION ALL
        SELECT 'availability', '', ev.message_class, ev.channel, ev.provider, count(*),
          count(*) FILTER (WHERE ev.event_type = 'attempt.succeeded')
        FROM ev
        WHERE ev.event_type IN ('attempt.succeeded', 'attempt.failed', 'attempt.unknown')
        GROUP BY ev.message_class, ev.channel, ev.provider
        UNION ALL
        SELECT 'gap', 'accepted_enqueued', n.message_class::text, d.channel::text,
          coalesce(d.provider, 'none'), count(*), 0
        FROM relay.delivery_events e
        JOIN relay.deliveries d ON d.tenant_id = e.tenant_id
          AND d.environment = e.environment AND d.id = e.delivery_id
        JOIN relay.notifications n ON n.tenant_id = d.tenant_id
          AND n.environment = d.environment AND n.id = d.notification_id
        WHERE e.event_type = 'delivery.queued'
          AND e.received_at > p_to - interval '65 minutes'
          AND e.received_at <= p_to - interval '5 minutes'
          AND d.decision = 'send' AND d.attempt_count = 0 AND d.failure_kind IS NULL
          AND d.deferred_until IS NULL AND d.paused_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM relay_queue.oban_jobs j
            WHERE j.args ->> 'delivery_id' = d.id::text)
          AND NOT EXISTS (SELECT 1 FROM relay_queue.drr_waits w
            WHERE w.args ->> 'delivery_id' = d.id::text)
        GROUP BY n.message_class, d.channel, d.provider
        UNION ALL
        SELECT 'queue_share', queued.queue, '', '', '', sum(queued.n)::bigint,
          max(queued.n)::bigint
        FROM queued
        GROUP BY queued.queue
      $fn$
      """
    ]
  end
end
