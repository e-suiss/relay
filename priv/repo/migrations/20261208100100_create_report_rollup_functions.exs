defmodule Relay.Repo.Migrations.CreateReportRollupFunctions do
  use Ecto.Migration

  @recompute "relay_fn.report_rollup_recompute(date)"
  @scopes "relay_ops.report_rollup_scopes(uuid, text, integer)"
  @counters ~w(accepted enqueued dispatched provider_accepted delivered engaged sdk_receipts
               skipped failed uncertain expired cancelled duplicate_delivered conflicts
               human_clicks bot_clicks opens machine_opens)

  # DS-35
  # DS-36
  # DS-39
  # OP-39
  # F-7
  # TN-18
  # OP-8
  def up do
    execute("""
    CREATE INDEX deliveries_created_at_index ON relay.deliveries
      (tenant_id, environment, created_at)
    """)

    execute(recompute())
    execute(scopes())

    execute("REVOKE ALL ON FUNCTION #{@recompute} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@recompute} TO relay_app")
    execute("ALTER FUNCTION #{@recompute} OWNER TO relay_owner")
    execute("REVOKE ALL ON FUNCTION #{@scopes} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@scopes} TO relay_worker")
  end

  def down, do: :ok

  defp recompute do
    zero = Enum.map_join(@counters, ", ", &"#{&1} = 0")
    columns = Enum.join(@counters, ", ")
    excluded = Enum.map_join(@counters, ", ", &"#{&1} = EXCLUDED.#{&1}")

    ~s"""
    CREATE FUNCTION relay_fn.report_rollup_recompute(p_day date)
      RETURNS TABLE (result text, delivery_rows bigint, skip_rows bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_from timestamptz;
      v_to timestamptz;
      v_delivery_rows bigint;
      v_skip_rows bigint;
    BEGIN
      IF p_day IS NULL OR p_day > current_date THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-35';
      END IF;
      v_from := p_day::timestamptz;
      v_to := (p_day + 1)::timestamptz;
      UPDATE relay.report_delivery_rollups r SET #{zero}, recomputed_at = now()
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.report_day = p_day;
      UPDATE relay.report_skip_rollups r SET skipped = 0, recomputed_at = now()
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.report_day = p_day;
      WITH d AS (
        SELECT d.id, d.channel, coalesce(d.provider, '') AS provider, n.is_test, d.decision,
          d.delivery_rank, d.failure_kind, d.duplicate_delivered, d.has_conflict
        FROM relay.deliveries d
        JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
          AND n.id = d.notification_id
        WHERE d.tenant_id = v_tenant AND d.environment = v_env
          AND d.created_at >= v_from AND d.created_at < v_to
      ), a AS (
        SELECT a.delivery_id, bool_or(a.started_at IS NOT NULL) AS dispatched,
          bool_or(a.state = 'unknown') AS uncertain
        FROM relay.delivery_attempts a
        WHERE a.tenant_id = v_tenant AND a.environment = v_env
          AND a.created_at >= v_from AND a.created_at < v_to + interval '30 days'
          AND a.delivery_id IN (SELECT d.id FROM d)
        GROUP BY a.delivery_id
      ), e AS (
        SELECT e.delivery_id, bool_or(e.actor = 'user') AS engaged,
          bool_or(e.actor = 'client_sdk') AS sdk_receipt,
          count(*) FILTER (WHERE e.event_type = 'engagement.clicked'
            AND e.detail ->> 'class' = 'human') AS human_clicks,
          count(*) FILTER (WHERE e.event_type = 'engagement.clicked'
            AND e.detail ->> 'class' = 'likely_bot') AS bot_clicks,
          count(*) FILTER (WHERE e.event_type = 'engagement.opened'
            AND (e.detail ->> 'machine_open') IS DISTINCT FROM 'true') AS opens,
          count(*) FILTER (WHERE e.event_type = 'engagement.opened'
            AND e.detail ->> 'machine_open' = 'true') AS machine_opens
        FROM relay.delivery_events e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env
          AND e.received_at >= v_from AND e.received_at < v_to + interval '30 days'
          AND e.delivery_id IN (SELECT d.id FROM d)
          AND (e.actor IN ('user', 'client_sdk')
            OR e.event_type IN ('engagement.clicked', 'engagement.opened'))
        GROUP BY e.delivery_id
      )
      INSERT INTO relay.report_delivery_rollups AS r (tenant_id, environment, report_day, channel,
        provider, is_test, #{columns}, recomputed_at)
      SELECT v_tenant, v_env, p_day, d.channel, d.provider, d.is_test, count(*),
        count(*) FILTER (WHERE d.decision <> 'skip'),
        count(*) FILTER (WHERE a.dispatched),
        count(*) FILTER (WHERE d.delivery_rank >= 1),
        count(*) FILTER (WHERE d.delivery_rank = 2),
        count(*) FILTER (WHERE e.engaged),
        count(*) FILTER (WHERE e.sdk_receipt),
        count(*) FILTER (WHERE d.decision = 'skip' OR d.failure_kind = 'skipped'),
        count(*) FILTER (WHERE d.failure_kind IN ('failed', 'bounced')),
        count(*) FILTER (WHERE a.uncertain AND d.delivery_rank < 2 AND d.failure_kind IS NULL),
        count(*) FILTER (WHERE d.failure_kind = 'expired'),
        count(*) FILTER (WHERE d.failure_kind = 'cancelled'),
        count(*) FILTER (WHERE d.duplicate_delivered),
        count(*) FILTER (WHERE d.has_conflict),
        coalesce(sum(e.human_clicks), 0), coalesce(sum(e.bot_clicks), 0),
        coalesce(sum(e.opens), 0), coalesce(sum(e.machine_opens), 0), now()
      FROM d
      LEFT JOIN a ON a.delivery_id = d.id
      LEFT JOIN e ON e.delivery_id = d.id
      GROUP BY d.channel, d.provider, d.is_test
      ON CONFLICT (tenant_id, environment, report_day, channel, provider, is_test)
        DO UPDATE SET #{excluded}, recomputed_at = EXCLUDED.recomputed_at;
      GET DIAGNOSTICS v_delivery_rows = ROW_COUNT;
      INSERT INTO relay.report_skip_rollups AS r (tenant_id, environment, report_day, channel,
        is_test, reason, rule_id, skipped, recomputed_at)
      SELECT v_tenant, v_env, p_day, d.channel, n.is_test,
        left(coalesce(d.failure_reason, d.decision_reason, 'unknown'), 128),
        left(coalesce(d.failure_rule_id, d.decision_rule_id, 'unknown'), 128), count(*), now()
      FROM relay.deliveries d
      JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
        AND n.id = d.notification_id
      WHERE d.tenant_id = v_tenant AND d.environment = v_env
        AND d.created_at >= v_from AND d.created_at < v_to
        AND (d.decision = 'skip' OR d.failure_kind = 'skipped')
      GROUP BY 4, 5, 6, 7
      ON CONFLICT (tenant_id, environment, report_day, channel, is_test, reason, rule_id)
        DO UPDATE SET skipped = EXCLUDED.skipped, recomputed_at = EXCLUDED.recomputed_at;
      GET DIAGNOSTICS v_skip_rows = ROW_COUNT;
      RETURN QUERY SELECT 'recomputed'::text, v_delivery_rows, v_skip_rows;
    END
    $fn$
    """
  end

  defp scopes do
    ~S"""
    CREATE FUNCTION relay_ops.report_rollup_scopes(p_after_tenant uuid, p_after_environment text,
      p_limit integer)
      RETURNS TABLE (tenant_id uuid, environment text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT t.id, e.environment
      FROM relay.tenants t
      CROSS JOIN (VALUES ('live'), ('test')) AS e (environment)
      WHERE t.status IN ('active', 'suspended')
        AND (p_after_tenant IS NULL OR (t.id, e.environment) > (p_after_tenant, p_after_environment))
      ORDER BY t.id, e.environment
      LIMIT least(greatest(coalesce(p_limit, 100), 1), 1000)
    $fn$
    """
  end
end
