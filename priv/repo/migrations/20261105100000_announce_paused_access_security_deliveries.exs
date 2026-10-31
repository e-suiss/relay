defmodule Relay.Repo.Migrations.AnnouncePausedAccessSecurityDeliveries do
  use Ecto.Migration

  # TN-42
  # TN-40
  # E-7
  # E-70
  # INV-2
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute(delivery_pause())
    execute("RESET ROLE")
  end

  defp delivery_pause do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.delivery_pause(p_delivery_id uuid, p_rule_id text,
      p_kill_switch_id uuid) RETURNS text
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
    BEGIN
      IF p_rule_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-40';
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
        RETURN 'already_paused';
      END IF;
      PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay', 'delivery.paused',
        NULL, NULL, NULL, now(), NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        jsonb_strip_nulls(jsonb_build_object('rule_id', v_rule, 'kill_switch_id',
          p_kill_switch_id)),
        v_delivery.traceparent);
      UPDATE relay.deliveries d SET paused_at = now(), pause_rule_id = v_rule,
          pause_kill_switch_id = p_kill_switch_id, updated_at = now()
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
      SELECT * INTO v_notification FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env
          AND n.id = v_delivery.notification_id;
      IF v_notification.message_class = 'security' AND EXISTS (
          SELECT 1 FROM relay.tenants t WHERE t.id = v_tenant AND t.platform_product = 'access')
      THEN
        PERFORM relay_fn.outbox_append(uuidv7(), 'delivery.paused',
          'delivery:' || p_delivery_id::text,
          jsonb_strip_nulls(jsonb_build_object('delivery_id', p_delivery_id,
            'notification_id', v_delivery.notification_id,
            'event_id', v_notification.event_id, 'channel', v_delivery.channel,
            'status', 'queued', 'reason', 'paused', 'rule_id', v_rule,
            'kill_switch_id', p_kill_switch_id, 'paused_at', now())),
          v_delivery.traceparent);
      END IF;
      RETURN 'paused';
    END
    $fn$
    """
  end
end
