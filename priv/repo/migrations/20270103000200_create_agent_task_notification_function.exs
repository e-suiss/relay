defmodule Relay.Repo.Migrations.CreateAgentTaskNotificationFunction do
  use Ecto.Migration

  @signature "relay_fn.agent_task_notification_apply(uuid, text, text, bigint, text, uuid, boolean)"

  # AG-37
  # AG-42
  # INV-35
  # OP-8
  def up do
    execute(apply_function())
    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp apply_function do
    ~S"""
    CREATE FUNCTION relay_fn.agent_task_notification_apply(p_source_id uuid, p_task text,
      p_protocol text, p_seq bigint, p_state text, p_receipt_id uuid, p_reconciled boolean)
      RETURNS TABLE (result text, seq bigint, state text)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.agent_task_notifications%ROWTYPE;
      v_state text;
    BEGIN
      IF p_source_id IS NULL OR p_task IS NULL OR p_protocol IS NULL OR p_seq IS NULL
        OR p_seq < 0 OR p_reconciled IS NULL OR p_protocol NOT IN ('a2a') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-37';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM relay.webhook_sources s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_source_id) THEN
        RETURN QUERY SELECT 'source_not_found'::text, NULL::bigint, NULL::text;
        RETURN;
      END IF;
      INSERT INTO relay.agent_task_notifications (tenant_id, environment, source_id, task,
        protocol, seq, state, receipt_id, reconciled_at, created_at, updated_at)
      VALUES (v_tenant, v_env, p_source_id, p_task, p_protocol, p_seq, p_state, p_receipt_id,
        CASE WHEN p_reconciled THEN now() END, now(), now())
      ON CONFLICT ON CONSTRAINT agent_task_notifications_pkey DO NOTHING;
      IF FOUND THEN
        v_state := p_state;
      ELSE
        SELECT * INTO v_row FROM relay.agent_task_notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.source_id = p_source_id
            AND n.task = p_task
          FOR UPDATE;
        IF p_seq = v_row.seq THEN
          RETURN QUERY SELECT 'duplicate'::text, v_row.seq, v_row.state;
          RETURN;
        END IF;
        IF p_seq < v_row.seq THEN
          RETURN QUERY SELECT 'stale'::text, v_row.seq, v_row.state;
          RETURN;
        END IF;
        v_state := COALESCE(p_state, v_row.state);
        UPDATE relay.agent_task_notifications n
          SET seq = p_seq, state = v_state, receipt_id = COALESCE(p_receipt_id, n.receipt_id),
            reconciled_at = CASE WHEN p_reconciled THEN now() ELSE n.reconciled_at END,
            updated_at = now()
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.source_id = p_source_id
            AND n.task = p_task;
      END IF;
      PERFORM relay_fn.outbox_append(uuidv7(), 'agent.task_notification_received',
        'agent_task:' || p_source_id::text,
        jsonb_strip_nulls(jsonb_build_object('webhook_source_id', p_source_id, 'protocol',
          p_protocol, 'task', p_task, 'seq', p_seq, 'state', v_state)),
        NULL);
      RETURN QUERY SELECT 'applied'::text, p_seq, v_state;
    END
    $fn$
    """
  end
end
