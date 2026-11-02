defmodule Relay.Repo.Migrations.CreateDeliveryDecisionFunction do
  use Ecto.Migration

  @signature "relay_fn.delivery_decide(uuid, text, text, text, timestamp with time zone, jsonb)"

  # PC-58 (2)
  # PC-8
  # DS-24
  # DS-26
  # DS-27
  # INV-2
  # OP-8
  def up do
    execute(delivery_decide())
    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: execute("DROP FUNCTION #{@signature}")

  defp delivery_decide do
    ~S"""
    CREATE FUNCTION relay_fn.delivery_decide(p_delivery_id uuid, p_decision text,
      p_reason text, p_rule_id text, p_deferred_until timestamptz, p_detail jsonb)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_delivery relay.deliveries;
      v_notification relay.notifications;
      v_rule relay.rule_id := p_rule_id;
      v_detail jsonb;
      v_workflow jsonb;
      v_skip boolean := p_decision = 'skip';
    BEGIN
      IF p_decision IS NULL OR p_decision NOT IN ('send', 'skip', 'defer', 'expire')
        OR (p_decision <> 'send' AND p_rule_id IS NULL)
        OR (p_decision IN ('skip', 'expire') AND p_reason IS NULL)
        OR (p_decision = 'defer') <> (p_deferred_until IS NOT NULL)
        OR (p_reason IS NOT NULL AND char_length(p_reason) NOT BETWEEN 1 AND 64)
        OR (p_detail IS NOT NULL AND jsonb_typeof(p_detail) <> 'object') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-58';
      END IF;
      SELECT * INTO v_delivery FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_delivery.failure_kind IS NOT NULL OR v_delivery.delivery_rank > 0 THEN
        RETURN 'already_terminal';
      END IF;
      IF v_delivery.paused_at IS NOT NULL THEN
        RETURN 'paused';
      END IF;
      IF p_decision = 'send' THEN
        IF v_delivery.decision = 'send' THEN
          RETURN 'unchanged';
        END IF;
        UPDATE relay.deliveries d SET decision = 'send', decision_reason = NULL,
            decision_rule_id = NULL, deferred_until = NULL, updated_at = now()
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
        RETURN 'recorded';
      END IF;
      v_detail := COALESCE(p_detail, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
        'reason', p_reason, 'rule_id', v_rule, 'deferred_until', p_deferred_until));
      IF p_decision = 'defer' THEN
        IF v_delivery.decision = 'defer' AND v_delivery.deferred_until = p_deferred_until
          AND v_delivery.decision_rule_id IS NOT DISTINCT FROM v_rule THEN
          RETURN 'unchanged';
        END IF;
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
          'delivery.deferred', NULL, NULL, NULL, now(), NULL, NULL, NULL, NULL, NULL, NULL, NULL,
          v_detail, v_delivery.traceparent);
        UPDATE relay.deliveries d SET decision = 'defer', decision_reason = p_reason,
            decision_rule_id = v_rule, deferred_until = p_deferred_until, updated_at = now()
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
        RETURN 'recorded';
      END IF;
      PERFORM relay_private.ledger_record(uuidv7(), v_delivery,
        NULLIF(v_delivery.attempt_count, 0), 'relay',
        CASE WHEN v_skip THEN 'delivery.skipped' ELSE 'delivery.expired' END, NULL, NULL, NULL,
        now(), NULL, NULL, CASE WHEN v_skip THEN 'skipped' ELSE 'expired' END, NULL, v_rule,
        p_reason, NULL, v_detail, v_delivery.traceparent);
      IF v_skip THEN
        UPDATE relay.deliveries d SET decision = 'skip', decision_reason = p_reason,
            decision_rule_id = v_rule, deferred_until = NULL, updated_at = now()
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
      END IF;
      SELECT * INTO v_notification FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env
          AND n.id = v_delivery.notification_id;
      SELECT jsonb_build_object('key', w.key, 'version', v.version_no) INTO v_workflow
        FROM relay.workflows w
        JOIN relay.workflow_versions v ON v.tenant_id = w.tenant_id
          AND v.environment = w.environment AND v.workflow_id = w.id
        WHERE w.tenant_id = v_tenant AND w.environment = v_env
          AND w.id = v_notification.workflow_id AND v.id = v_notification.workflow_version_id;
      PERFORM relay_fn.outbox_append(uuidv7(), 'notification.suppressed',
        'delivery:' || p_delivery_id::text,
        jsonb_strip_nulls(jsonb_build_object('notification_id', v_delivery.notification_id,
          'delivery_id', p_delivery_id, 'recipient_id', v_notification.recipient_id,
          'workflow', v_workflow, 'tenant', v_notification.subtenant_id,
          'channel', v_delivery.channel, 'reason', p_reason, 'rule_id', v_rule)),
        v_delivery.traceparent);
      RETURN 'recorded';
    END
    $fn$
    """
  end
end
