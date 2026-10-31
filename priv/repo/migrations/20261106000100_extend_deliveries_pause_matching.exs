defmodule Relay.Repo.Migrations.ExtendDeliveriesPauseMatching do
  use Ecto.Migration

  @function "relay_fn.deliveries_pause_matching(uuid, integer)"

  # TN-40
  # TN-40 (2)
  # TN-41
  # OP-8
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute("DROP FUNCTION #{@function}")
    execute("RESET ROLE")
    execute(deliveries_pause_matching())
    execute("REVOKE ALL ON FUNCTION #{@function} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@function} TO relay_app")
    execute("ALTER FUNCTION #{@function} OWNER TO relay_owner")
  end

  defp deliveries_pause_matching do
    ~S"""
    CREATE FUNCTION relay_fn.deliveries_pause_matching(p_kill_switch_id uuid, p_limit integer)
      RETURNS TABLE (paused bigint, has_more boolean)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_limit integer := least(greatest(coalesce(p_limit, 500), 1), 5000);
      v_ks relay.kill_switches;
      v_rule text;
      v_ids uuid[];
      v_id uuid;
      v_count bigint := 0;
    BEGIN
      SELECT * INTO v_ks FROM relay.kill_switches k
        WHERE k.id = p_kill_switch_id AND k.status = 'active'
          AND (k.expires_at IS NULL OR k.expires_at > now())
          AND (k.state = 'off' OR k.state = 'canary'
            OR (k.state = 'paused_until' AND k.paused_until > now()));
      IF NOT FOUND THEN
        RETURN QUERY SELECT 0::bigint, false;
        RETURN;
      END IF;
      v_rule := 'killswitch.' || v_ks.state;
      SELECT array_agg(c.id) INTO v_ids FROM (
        SELECT d.id FROM relay.deliveries d
        JOIN relay.notifications n ON n.tenant_id = d.tenant_id
          AND n.environment = d.environment AND n.id = d.notification_id
        LEFT JOIN relay.events e ON e.tenant_id = n.tenant_id
          AND e.environment = n.environment AND e.id = n.event_id
        WHERE d.tenant_id = v_tenant AND d.environment = v_env
          AND d.delivery_rank = 0 AND d.failure_kind IS NULL AND d.paused_at IS NULL
          AND CASE v_ks.scope_kind
            WHEN 'platform' THEN true
            WHEN 'tenant' THEN true
            WHEN 'subtenant' THEN n.subtenant_id::text = v_ks.scope_ref
            WHEN 'workflow' THEN n.workflow_id::text = v_ks.scope_ref
            WHEN 'api_client' THEN e.api_client_id::text = v_ks.scope_ref
            ELSE false END
          AND (v_ks.channel IS NULL OR d.channel = v_ks.channel)
          AND CASE v_ks.target_kind
            WHEN 'all' THEN true
            WHEN 'provider_account' THEN d.provider_account_id::text = v_ks.target_ref
            ELSE false END
          AND ((v_ks.message_class IS NULL AND n.message_class <> 'security')
            OR n.message_class = v_ks.message_class)
          AND (v_ks.state <> 'canary' OR relay_private.canary_bucket(d.tenant_id,
            d.environment::text, d.notification_id) >= v_ks.canary_percent)
        ORDER BY d.created_at, d.id
        LIMIT v_limit + 1
        FOR UPDATE OF d) c;
      IF v_ids IS NULL THEN
        RETURN QUERY SELECT 0::bigint, false;
        RETURN;
      END IF;
      FOREACH v_id IN ARRAY v_ids[1:v_limit]
      LOOP
        IF relay_fn.delivery_pause(v_id, v_rule, p_kill_switch_id) = 'paused' THEN
          v_count := v_count + 1;
        END IF;
      END LOOP;
      RETURN QUERY SELECT v_count, cardinality(v_ids) > v_limit;
    END
    $fn$
    """
  end
end
