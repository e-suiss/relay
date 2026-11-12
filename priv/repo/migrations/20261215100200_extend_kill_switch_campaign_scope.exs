defmodule Relay.Repo.Migrations.ExtendKillSwitchCampaignScope do
  use Ecto.Migration

  @gate "relay_fn.delivery_gate(uuid)"
  @matching "relay_fn.deliveries_pause_matching(uuid, integer)"

  # TN-40
  # TN-41
  # OP-47
  # WF-44
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute("DROP FUNCTION #{@gate}")
    execute("DROP FUNCTION #{@matching}")
    execute("RESET ROLE")
    execute(delivery_gate())
    execute(deliveries_pause_matching())

    for function <- [@gate, @matching] do
      execute("REVOKE ALL ON FUNCTION #{function} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{function} TO relay_app")
      execute("ALTER FUNCTION #{function} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp delivery_gate do
    ~S"""
    CREATE FUNCTION relay_fn.delivery_gate(p_delivery_id uuid)
      RETURNS TABLE (result text, channel text, message_class text, subtenant_id uuid,
        provider_account_id uuid, notification_id uuid, expires_at timestamptz,
        attempt_count bigint, workflow_id uuid, api_client_id uuid, campaign_id uuid)
    LANGUAGE plpgsql STABLE SECURITY INVOKER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_delivery relay.deliveries;
      v_notification relay.notifications;
      v_api_client uuid;
      v_campaign uuid;
      v_result text;
    BEGIN
      SELECT * INTO v_delivery FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::text, NULL::text, NULL::uuid, NULL::uuid,
          NULL::uuid, NULL::timestamptz, NULL::bigint, NULL::uuid, NULL::uuid, NULL::uuid;
        RETURN;
      END IF;
      SELECT * INTO v_notification FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env
          AND n.id = v_delivery.notification_id;
      IF v_notification.event_id IS NOT NULL THEN
        SELECT e.api_client_id INTO v_api_client FROM relay.events e
          WHERE e.tenant_id = v_tenant AND e.environment = v_env
            AND e.id = v_notification.event_id;
      END IF;
      SELECT m.campaign_id INTO v_campaign FROM relay.campaign_members m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env
          AND m.notification_id = v_delivery.notification_id
        LIMIT 1;
      v_result := CASE
        WHEN v_delivery.failure_kind = 'cancelled' THEN 'cancelled'
        WHEN v_delivery.failure_kind IS NOT NULL OR v_delivery.delivery_rank > 0 THEN 'terminal'
        WHEN v_delivery.paused_at IS NOT NULL THEN 'paused'
        WHEN v_notification.expires_at IS NOT NULL AND v_notification.expires_at <= now()
          THEN 'expired'
        WHEN v_delivery.decision = 'defer' AND v_delivery.deferred_until > now() THEN 'deferred'
        ELSE 'sendable'
      END;
      RETURN QUERY SELECT v_result, v_delivery.channel::text, v_notification.message_class::text,
        v_notification.subtenant_id, v_delivery.provider_account_id, v_delivery.notification_id,
        v_notification.expires_at, v_delivery.attempt_count, v_notification.workflow_id,
        v_api_client, v_campaign;
    END
    $fn$
    """
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
            WHEN 'campaign' THEN EXISTS (SELECT 1 FROM relay.campaign_members m
              WHERE m.tenant_id = d.tenant_id AND m.environment = d.environment
                AND m.notification_id = d.notification_id
                AND m.campaign_id::text = v_ks.scope_ref)
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
