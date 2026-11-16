defmodule Relay.Repo.Migrations.KeyDeliveriesByStep do
  use Ecto.Migration

  @open "relay_fn.delivery_open(uuid, uuid, text, text, uuid, bytea, text, uuid, uuid, text, text, text, timestamp with time zone, text, text)"

  # WF-63
  # WF-36
  # INV-12
  # OP-57
  def up do
    execute("ALTER TABLE relay.deliveries VALIDATE CONSTRAINT deliveries_step_ref_check")
    execute("ALTER TABLE relay.deliveries DROP CONSTRAINT deliveries_target_key")

    execute(
      "ALTER TABLE relay.deliveries ADD CONSTRAINT deliveries_target_key UNIQUE USING INDEX deliveries_step_key"
    )

    execute("SET LOCAL ROLE relay_owner")
    execute(open())
    execute(wrapper())
    execute("REVOKE ALL ON FUNCTION #{@open} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@open} TO relay_app")
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp open do
    ~S"""
    CREATE FUNCTION relay_fn.delivery_open(p_id uuid, p_notification_id uuid, p_channel text,
      p_target_kind text, p_target_id uuid, p_target_key bytea, p_provider text,
      p_provider_account_id uuid, p_fallback_of uuid, p_decision text, p_decision_reason text,
      p_decision_rule_id text, p_deferred_until timestamptz, p_traceparent text,
      p_step_ref text)
      RETURNS TABLE (result text, delivery_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_notification relay.notifications;
      v_existing uuid;
      v_event text;
      v_now timestamptz := clock_timestamp();
      v_new relay_private.delivery_projection;
      v_skip boolean := p_decision = 'skip';
      v_step text := coalesce(p_step_ref, '');
    BEGIN
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      IF p_decision IS NULL OR p_decision NOT IN ('send', 'skip', 'defer')
        OR (p_decision <> 'send' AND p_decision_rule_id IS NULL)
        OR (p_decision = 'defer') <> (p_deferred_until IS NOT NULL)
        OR p_channel IS NULL OR p_target_kind IS NULL
        OR p_target_key IS NULL OR octet_length(p_target_key) <> 32 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-1';
      END IF;
      SELECT * INTO v_notification FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = p_notification_id
        FOR SHARE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'notification_not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      SELECT d.id INTO v_existing FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env
          AND d.notification_id = p_notification_id AND d.channel = p_channel
          AND d.target_key = p_target_key AND d.step_ref = v_step;
      IF FOUND THEN
        RETURN QUERY SELECT 'exists'::text, v_existing;
        RETURN;
      END IF;
      IF v_notification.state <> 'active' THEN
        RETURN QUERY SELECT 'notification_closed'::text, NULL::uuid;
        RETURN;
      END IF;
      IF p_fallback_of IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_fallback_of
          AND d.notification_id = p_notification_id) THEN
        RETURN QUERY SELECT 'fallback_invalid'::text, NULL::uuid;
        RETURN;
      END IF;
      v_event := CASE p_decision WHEN 'send' THEN 'delivery.queued'
        WHEN 'skip' THEN 'delivery.skipped' ELSE 'delivery.deferred' END;
      v_new := relay_private.projection_apply(relay_private.projection_zero(), v_event, NULL, NULL,
        v_now, v_now, NULL,
        CASE WHEN v_skip THEN 'skipped' END, NULL,
        CASE WHEN v_skip THEN p_decision_rule_id END,
        CASE WHEN v_skip THEN p_decision_reason END,
        NULL, false);
      INSERT INTO relay.deliveries AS d (tenant_id, environment, id, notification_id, recipient_id,
        channel, target_kind, target_id, target_key, provider, provider_account_id, fallback_of,
        decision, decision_reason, decision_rule_id, deferred_until, delivery_rank, accepted_at,
        delivered_at, failure_kind, failure_class, failure_rule_id, failure_reason,
        failure_attempt_no, failure_provider_seq, failure_occurred_at, failure_received_at,
        has_conflict, duplicate_delivered, attempt_count, late_event_count, projection_version,
        last_event_at, traceparent, step_ref, created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_notification_id, v_notification.recipient_id, p_channel,
        p_target_kind, p_target_id, p_target_key, p_provider, p_provider_account_id, p_fallback_of,
        p_decision, p_decision_reason, p_decision_rule_id, p_deferred_until, v_new.delivery_rank,
        v_new.accepted_at, v_new.delivered_at, v_new.failure_kind, v_new.failure_class,
        v_new.failure_rule_id, v_new.failure_reason, v_new.failure_attempt_no,
        v_new.failure_provider_seq, v_new.failure_occurred_at, v_new.failure_received_at,
        v_new.has_conflict, v_new.duplicate_delivered, 0, v_new.late_event_count,
        v_new.projection_version, v_new.last_event_at, p_traceparent, v_step, now(), now())
      ON CONFLICT (tenant_id, environment, notification_id, channel, target_key, step_ref)
        DO NOTHING
      RETURNING d.id INTO v_existing;
      IF v_existing IS NULL THEN
        SELECT d.id INTO v_existing FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env
            AND d.notification_id = p_notification_id AND d.channel = p_channel
            AND d.target_key = p_target_key AND d.step_ref = v_step;
        RETURN QUERY SELECT 'exists'::text, v_existing;
        RETURN;
      END IF;
      INSERT INTO relay.delivery_events (tenant_id, environment, id, received_at, delivery_id,
        attempt_no, actor, event_type, raw_code, provider, provider_seq, occurred_at, receipt_id,
        projection_result, detail, evidence_version_id, traceparent)
      VALUES (v_tenant, v_env, uuidv7(), v_now, p_id, NULL, 'relay', v_event, NULL, NULL, NULL,
        v_now, NULL, v_new.result,
        jsonb_build_object('effect', jsonb_strip_nulls(jsonb_build_object(
          'failure_kind', v_new.failure_kind, 'failure_rule_id', v_new.failure_rule_id,
          'failure_reason', v_new.failure_reason))),
        NULL, p_traceparent);
      RETURN QUERY SELECT 'opened'::text, p_id;
    END
    $fn$
    """
  end

  defp wrapper do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.delivery_open(p_id uuid, p_notification_id uuid,
      p_channel text, p_target_kind text, p_target_id uuid, p_target_key bytea, p_provider text,
      p_provider_account_id uuid, p_fallback_of uuid, p_decision text, p_decision_reason text,
      p_decision_rule_id text, p_deferred_until timestamptz, p_traceparent text)
      RETURNS TABLE (result text, delivery_id uuid)
    LANGUAGE sql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT o.result, o.delivery_id FROM relay_fn.delivery_open(p_id, p_notification_id, p_channel,
        p_target_kind, p_target_id, p_target_key, p_provider, p_provider_account_id, p_fallback_of,
        p_decision, p_decision_reason, p_decision_rule_id, p_deferred_until, p_traceparent, '') o
    $fn$
    """
  end
end
