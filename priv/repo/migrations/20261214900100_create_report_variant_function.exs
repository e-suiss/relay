defmodule Relay.Repo.Migrations.CreateReportVariantFunction do
  use Ecto.Migration

  @recompute "relay_fn.report_variant_recompute(date)"

  # WF-50
  # DS-35
  # DS-39
  # TN-18
  def up do
    execute(recompute())
    execute("REVOKE ALL ON FUNCTION #{@recompute} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@recompute} TO relay_app")
    execute("ALTER FUNCTION #{@recompute} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp recompute do
    ~S"""
    CREATE FUNCTION relay_fn.report_variant_recompute(p_day date)
      RETURNS TABLE (result text, variant_rows bigint)
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
      v_rows bigint;
    BEGIN
      IF p_day IS NULL OR p_day > current_date THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-50';
      END IF;
      v_from := p_day::timestamptz;
      v_to := (p_day + 1)::timestamptz;
      UPDATE relay.report_variant_rollups r SET accepted = 0, sent = 0, delivered = 0, seen = 0,
          human_clicks = 0, bot_clicks = 0, recomputed_at = now()
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.report_day = p_day;
      WITH d AS (
        SELECT d.id, d.channel, n.is_test, d.delivery_rank, d.seen_at,
          w.key::text AS workflow_key, split_part(d.step_ref, '/', 1) AS step_key,
          r.step_results -> split_part(d.step_ref, '/', 1) ->> 'variant' AS variant
        FROM relay.deliveries d
        JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
          AND n.id = d.notification_id
        JOIN relay.workflow_runs r ON r.tenant_id = d.tenant_id
          AND r.environment = d.environment AND r.notification_id = d.notification_id
        JOIN relay.workflows w ON w.tenant_id = r.tenant_id AND w.environment = r.environment
          AND w.id = r.workflow_id
        WHERE d.tenant_id = v_tenant AND d.environment = v_env
          AND d.created_at >= v_from AND d.created_at < v_to AND d.step_ref <> ''
      ), e AS (
        SELECT e.delivery_id,
          count(*) FILTER (WHERE e.detail ->> 'class' = 'human') AS human_clicks,
          count(*) FILTER (WHERE e.detail ->> 'class' = 'likely_bot') AS bot_clicks
        FROM relay.delivery_events e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env
          AND e.received_at >= v_from AND e.received_at < v_to + interval '30 days'
          AND e.event_type = 'engagement.clicked'
          AND e.delivery_id IN (SELECT d.id FROM d WHERE d.variant IS NOT NULL)
        GROUP BY e.delivery_id
      )
      INSERT INTO relay.report_variant_rollups AS r (tenant_id, environment, report_day,
        workflow_key, step_key, variant, channel, is_test, accepted, sent, delivered, seen,
        human_clicks, bot_clicks, recomputed_at)
      SELECT v_tenant, v_env, p_day, d.workflow_key, left(d.step_key, 128), left(d.variant, 128),
        d.channel, d.is_test, count(*),
        count(*) FILTER (WHERE d.delivery_rank >= 1),
        count(*) FILTER (WHERE d.delivery_rank = 2),
        count(*) FILTER (WHERE d.seen_at IS NOT NULL),
        coalesce(sum(e.human_clicks), 0), coalesce(sum(e.bot_clicks), 0), now()
      FROM d
      LEFT JOIN e ON e.delivery_id = d.id
      WHERE d.variant IS NOT NULL
      GROUP BY d.workflow_key, d.step_key, d.variant, d.channel, d.is_test
      ON CONFLICT (tenant_id, environment, report_day, workflow_key, step_key, variant, channel,
        is_test)
        DO UPDATE SET accepted = EXCLUDED.accepted, sent = EXCLUDED.sent,
          delivered = EXCLUDED.delivered, seen = EXCLUDED.seen,
          human_clicks = EXCLUDED.human_clicks, bot_clicks = EXCLUDED.bot_clicks,
          recomputed_at = EXCLUDED.recomputed_at;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      RETURN QUERY SELECT 'recomputed'::text, v_rows;
    END
    $fn$
    """
  end
end
