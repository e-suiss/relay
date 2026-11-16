defmodule Relay.Repo.Migrations.AllowInboxRenderFailure do
  use Ecto.Migration

  # IN-49
  # TP-41
  # INV-46
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute(render_fail())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp render_fail do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.delivery_render_fail(p_delivery_id uuid,
      p_failure_reason text, p_detail jsonb)
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
      v_workflow jsonb;
      v_template jsonb;
      v_detail jsonb;
    BEGIN
      IF p_failure_reason IS NULL OR p_failure_reason NOT IN ('missing_variable',
        'render_timeout', 'output_too_large', 'schema_violation', 'inbox_item_too_large')
        OR (p_detail IS NOT NULL AND jsonb_typeof(p_detail) <> 'object') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'TP-41';
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
      SELECT * INTO v_notification FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env
          AND n.id = v_delivery.notification_id;
      SELECT jsonb_build_object('key', w.key, 'version', v.version_no) INTO v_workflow
        FROM relay.workflows w
        JOIN relay.workflow_versions v ON v.tenant_id = w.tenant_id
          AND v.environment = w.environment AND v.workflow_id = w.id
        WHERE w.tenant_id = v_tenant AND w.environment = v_env
          AND w.id = v_notification.workflow_id AND v.id = v_notification.workflow_version_id;
      SELECT jsonb_build_object('key', t.key, 'version', v.version_no) INTO v_template
        FROM relay.delivery_render_plans p
        JOIN relay.template_versions v ON v.tenant_id = p.tenant_id
          AND v.environment = p.environment AND v.id = p.template_version_id
        JOIN relay.templates t ON t.tenant_id = v.tenant_id AND t.environment = v.environment
          AND t.id = v.template_id
        WHERE p.tenant_id = v_tenant AND p.environment = v_env
          AND p.delivery_id = p_delivery_id;
      v_detail := COALESCE(p_detail, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
        'failure_reason', p_failure_reason, 'template', v_template));
      PERFORM relay_private.ledger_record(uuidv7(), v_delivery,
        NULLIF(v_delivery.attempt_count, 0), 'relay', 'delivery.render_failed', NULL, NULL,
        NULL, now(), NULL, NULL, 'failed', 'permanent_content', NULL, p_failure_reason, NULL,
        v_detail, v_delivery.traceparent);
      PERFORM relay_fn.outbox_append(uuidv7(), 'notification.render_failed',
        'delivery:' || p_delivery_id::text,
        jsonb_strip_nulls(jsonb_build_object('notification_id', v_delivery.notification_id,
          'delivery_id', p_delivery_id, 'recipient_id', v_notification.recipient_id,
          'workflow', v_workflow, 'template', v_template,
          'tenant', v_notification.subtenant_id, 'channel', v_delivery.channel,
          'failure_reason', p_failure_reason)),
        v_delivery.traceparent);
      RETURN 'failed';
    END
    $fn$
    """
  end
end
