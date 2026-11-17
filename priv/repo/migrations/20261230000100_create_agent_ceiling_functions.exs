defmodule Relay.Repo.Migrations.CreateAgentCeilingFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    "relay_fn.agent_ceiling_attribute(uuid, uuid)",
    "relay_fn.agent_ceiling_pass(uuid, uuid)",
    "relay_fn.agent_ceiling_hold(uuid, uuid, uuid, text)",
    "relay_fn.agent_ceiling_decide(uuid, uuid, uuid, text, text, text, bytea, #{@actor})",
    "relay_fn.agent_ceiling_apply(uuid, integer)",
    "relay_fn.agent_resume(uuid, text, bytea, #{@actor})"
  ]

  @expire "relay_fn.paused_deliveries_expire(integer)"

  # AG-48
  # AG-49
  # AG-50
  # INV-3
  # INV-34
  # TN-21
  # TN-47
  # OP-8
  def up do
    Enum.each([attribute(), pass(), hold(), decide(), apply_decision(), resume()], &execute/1)

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end

    execute("SET LOCAL ROLE relay_owner")
    execute("DROP FUNCTION #{@expire}")
    execute("RESET ROLE")
    execute(paused_deliveries_expire())
    execute("REVOKE ALL ON FUNCTION #{@expire} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@expire} TO relay_app")
    execute("ALTER FUNCTION #{@expire} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp attribute do
    ~S"""
    CREATE FUNCTION relay_fn.agent_ceiling_attribute(p_notification_id uuid, p_agent_ref uuid)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_sender text;
    BEGIN
      IF p_notification_id IS NULL OR p_agent_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-48';
      END IF;
      SELECT n.sender_type INTO v_sender FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = p_notification_id;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_sender <> 'agent' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'INV-34';
      END IF;
      INSERT INTO relay.agent_ceiling_holds (tenant_id, environment, notification_id, agent_ref,
        state, rule_id, ceiling_event_id, decision_id, expires_at, held_at, decided_at,
        applied_at, created_at, updated_at)
      VALUES (v_tenant, v_env, p_notification_id, p_agent_ref, 'pending', NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, now(), now())
      ON CONFLICT (tenant_id, environment, notification_id) DO NOTHING;
      IF FOUND THEN
        RETURN 'attributed';
      END IF;
      RETURN 'exists';
    END
    $fn$
    """
  end

  defp pass do
    ~S"""
    CREATE FUNCTION relay_fn.agent_ceiling_pass(p_notification_id uuid, p_agent_ref uuid)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_sender text;
      v_state text;
    BEGIN
      IF p_notification_id IS NULL OR p_agent_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-48';
      END IF;
      SELECT n.sender_type INTO v_sender FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = p_notification_id;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_sender <> 'agent' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'INV-34';
      END IF;
      INSERT INTO relay.agent_ceiling_holds (tenant_id, environment, notification_id, agent_ref,
        state, rule_id, ceiling_event_id, decision_id, expires_at, held_at, decided_at,
        applied_at, created_at, updated_at)
      VALUES (v_tenant, v_env, p_notification_id, p_agent_ref, 'passed', NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, now(), now())
      ON CONFLICT (tenant_id, environment, notification_id) DO NOTHING;
      IF FOUND THEN
        RETURN 'passed';
      END IF;
      SELECT h.state INTO v_state FROM relay.agent_ceiling_holds h
        WHERE h.tenant_id = v_tenant AND h.environment = v_env
          AND h.notification_id = p_notification_id
        FOR UPDATE;
      IF v_state = 'pending' THEN
        UPDATE relay.agent_ceiling_holds h SET state = 'passed', updated_at = now()
          WHERE h.tenant_id = v_tenant AND h.environment = v_env
            AND h.notification_id = p_notification_id;
        RETURN 'passed';
      END IF;
      IF v_state = 'passed' THEN
        RETURN 'already_passed';
      END IF;
      RETURN v_state;
    END
    $fn$
    """
  end

  defp hold do
    ~S"""
    CREATE FUNCTION relay_fn.agent_ceiling_hold(p_event_id uuid, p_delivery_id uuid,
      p_agent_ref uuid, p_rule_id text)
      RETURNS TABLE (result text, ceiling_event_id uuid, held_count bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_delivery relay.deliveries;
      v_notification relay.notifications;
      v_hold relay.agent_ceiling_holds;
      v_known boolean;
      v_pending boolean;
      v_event_id uuid;
      v_rule text := p_rule_id;
      v_count bigint;
    BEGIN
      IF p_event_id IS NULL OR p_delivery_id IS NULL OR p_agent_ref IS NULL OR p_rule_id IS NULL
        OR p_rule_id NOT IN ('agent_ceiling.exceeded', 'agent_ceiling.counter_unreadable') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-49';
      END IF;
      SELECT * INTO v_delivery FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::bigint;
        RETURN;
      END IF;
      SELECT * INTO v_notification FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env
          AND n.id = v_delivery.notification_id;
      IF v_notification.sender_type <> 'agent' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'INV-34';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['agent_ceiling', p_agent_ref::text]);
      SELECT * INTO v_hold FROM relay.agent_ceiling_holds h
        WHERE h.tenant_id = v_tenant AND h.environment = v_env
          AND h.notification_id = v_notification.id
        FOR UPDATE;
      v_known := FOUND AND v_hold.state <> 'pending';
      v_pending := FOUND AND v_hold.state = 'pending';
      IF v_known AND v_hold.state <> 'held' THEN
        RETURN QUERY SELECT v_hold.state, v_hold.ceiling_event_id, NULL::bigint;
        RETURN;
      END IF;
      IF v_known THEN
        v_event_id := v_hold.ceiling_event_id;
        v_rule := v_hold.rule_id;
        SELECT e.held_count INTO v_count FROM relay.agent_ceiling_events e
          WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = v_event_id;
      ELSE
        SELECT e.id INTO v_event_id FROM relay.agent_ceiling_events e
          WHERE e.tenant_id = v_tenant AND e.environment = v_env
            AND e.agent_ref = p_agent_ref AND e.state = 'open'
          FOR UPDATE;
        IF NOT FOUND THEN
          v_event_id := p_event_id;
          INSERT INTO relay.agent_ceiling_events (tenant_id, environment, id, agent_ref, rule_id,
            held_count, state, decided_at, created_at, updated_at)
          VALUES (v_tenant, v_env, v_event_id, p_agent_ref, p_rule_id, 0, 'open', NULL, now(),
            now());
          PERFORM relay_fn.outbox_append(v_event_id, 'agent.ceiling_exceeded',
            'agent:' || p_agent_ref::text,
            jsonb_build_object('agent_id', p_agent_ref, 'held_count', 1),
            v_delivery.traceparent);
        END IF;
        IF v_pending THEN
          UPDATE relay.agent_ceiling_holds h
            SET state = 'held', rule_id = p_rule_id, ceiling_event_id = v_event_id,
              expires_at = v_notification.expires_at, held_at = now(), updated_at = now()
            WHERE h.tenant_id = v_tenant AND h.environment = v_env
              AND h.notification_id = v_notification.id;
        ELSE
          INSERT INTO relay.agent_ceiling_holds (tenant_id, environment, notification_id,
            agent_ref, state, rule_id, ceiling_event_id, decision_id, expires_at, held_at,
            decided_at, applied_at, created_at, updated_at)
          VALUES (v_tenant, v_env, v_notification.id, p_agent_ref, 'held', p_rule_id, v_event_id,
            NULL, v_notification.expires_at, now(), NULL, NULL, now(), now());
        END IF;
        UPDATE relay.agent_ceiling_events e SET held_count = e.held_count + 1, updated_at = now()
          WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = v_event_id
          RETURNING e.held_count INTO v_count;
      END IF;
      PERFORM relay_fn.delivery_pause(p_delivery_id, v_rule, NULL);
      RETURN QUERY SELECT 'held'::text, v_event_id, v_count;
    END
    $fn$
    """
  end

  defp decide do
    ~S"""
    CREATE FUNCTION relay_fn.agent_ceiling_decide(p_id uuid, p_agent_ref uuid,
      p_ceiling_event_id uuid, p_decision text, p_decision_ref text, p_note text,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS TABLE (result text, decision_id uuid, applied_count bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_existing relay.agent_ceiling_decisions;
      v_count bigint;
    BEGIN
      IF p_agent_ref IS NULL OR p_ceiling_event_id IS NULL OR p_decision IS NULL
        OR p_decision NOT IN ('send_all', 'cancel', 'stop') OR p_decision_ref IS NULL
        OR p_actor_ref IS NULL OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-49';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM relay.agents c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_agent_ref) THEN
        RETURN QUERY SELECT 'agent_not_found'::text, NULL::uuid, NULL::bigint;
        RETURN;
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['agent_ceiling', p_agent_ref::text]);
      IF NOT EXISTS (SELECT 1 FROM relay.agent_ceiling_events e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_ceiling_event_id
          AND e.agent_ref = p_agent_ref) THEN
        RETURN QUERY SELECT 'ceiling_event_not_found'::text, NULL::uuid, NULL::bigint;
        RETURN;
      END IF;
      SELECT * INTO v_existing FROM relay.agent_ceiling_decisions x
        WHERE x.tenant_id = v_tenant AND x.environment = v_env
          AND x.ceiling_event_id = p_ceiling_event_id;
      IF FOUND THEN
        RETURN QUERY SELECT
          CASE WHEN v_existing.decision = p_decision THEN 'exists' ELSE 'conflict' END,
          v_existing.id, v_existing.applied_count;
        RETURN;
      END IF;
      IF p_decision = 'send_all' AND p_access_record_ref IS NULL THEN
        RETURN QUERY SELECT 'step_up_required'::text, NULL::uuid, NULL::bigint;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      SELECT count(*) INTO v_count FROM relay.agent_ceiling_holds h
        WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.agent_ref = p_agent_ref
          AND h.state = 'held';
      INSERT INTO relay.agent_ceiling_decisions (tenant_id, environment, id, agent_ref,
        ceiling_event_id, decision, decision_ref, note, applied_count, decided_by_ref,
        step_up_ref, decided_at, created_at)
      VALUES (v_tenant, v_env, p_id, p_agent_ref, p_ceiling_event_id, p_decision, p_decision_ref,
        p_note, v_count, p_actor_ref, p_access_record_ref, now(), now());
      UPDATE relay.agent_ceiling_holds h
        SET state = CASE WHEN p_decision = 'send_all' THEN 'released' ELSE 'cancelled' END,
          decision_id = p_id, decided_at = now(), updated_at = now()
        WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.agent_ref = p_agent_ref
          AND h.state = 'held';
      UPDATE relay.agent_ceiling_events e
        SET state = 'decided', decided_at = now(), updated_at = now()
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.agent_ref = p_agent_ref
          AND e.state = 'open';
      IF p_decision = 'stop' THEN
        INSERT INTO relay.agent_run_states AS s (tenant_id, environment, agent_ref, state,
          decision_ref, changed_at, created_at, updated_at)
        VALUES (v_tenant, v_env, p_agent_ref, 'stopped', p_decision_ref, now(), now(), now())
        ON CONFLICT (tenant_id, environment, agent_ref) DO UPDATE
          SET state = 'stopped', decision_ref = EXCLUDED.decision_ref, changed_at = now(),
            updated_at = now();
      END IF;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'agent.ceiling_decided',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
        'agent_ceiling_decision', p_id::text, p_decision, p_record_digest);
      RETURN QUERY SELECT 'decided'::text, p_id, v_count;
    END
    $fn$
    """
  end

  defp apply_decision do
    ~S"""
    CREATE FUNCTION relay_fn.agent_ceiling_apply(p_decision_id uuid, p_limit integer)
      RETURNS TABLE (outcome text, delivery_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 1000);
      v_decision relay.agent_ceiling_decisions;
      v_hold relay.agent_ceiling_holds;
      v_delivery relay.deliveries;
      v_expired boolean;
      v_any boolean;
    BEGIN
      SELECT * INTO v_decision FROM relay.agent_ceiling_decisions x
        WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.id = p_decision_id;
      IF NOT FOUND THEN
        RETURN;
      END IF;
      FOR v_hold IN
        SELECT * FROM relay.agent_ceiling_holds h
        WHERE h.tenant_id = v_tenant AND h.environment = v_env
          AND h.decision_id = p_decision_id AND h.applied_at IS NULL
        ORDER BY h.notification_id
        LIMIT v_limit
        FOR UPDATE
      LOOP
        v_expired := v_hold.state = 'released' AND v_hold.expires_at IS NOT NULL
          AND v_hold.expires_at <= relay_private.business_now();
        v_any := false;
        FOR v_delivery IN
          SELECT * FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env
            AND d.notification_id = v_hold.notification_id
            AND d.paused_at IS NOT NULL AND d.pause_kill_switch_id IS NULL
            AND d.pause_rule_id IN ('agent_ceiling.exceeded', 'agent_ceiling.counter_unreadable')
            AND d.failure_kind IS NULL AND d.delivery_rank = 0
          ORDER BY d.created_at, d.id
          FOR UPDATE
        LOOP
          v_any := true;
          IF v_hold.state = 'cancelled' THEN
            PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
              'delivery.cancelled', NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL,
              'agent_ceiling.cancelled', NULL, NULL,
              jsonb_build_object('ceiling_decision_id', p_decision_id), v_delivery.traceparent);
            RETURN QUERY SELECT 'cancelled'::text, v_delivery.id;
          ELSIF v_expired THEN
            PERFORM relay_fn.delivery_expire(v_delivery.id, 'agent_ceiling.expired');
            RETURN QUERY SELECT 'expired'::text, v_delivery.id;
          ELSE
            PERFORM relay_fn.delivery_resume(v_delivery.id, v_decision.decision_ref,
              'agent_ceiling.released');
            RETURN QUERY SELECT 'resumed'::text, v_delivery.id;
          END IF;
        END LOOP;
        IF NOT v_any THEN
          RETURN QUERY SELECT 'none'::text, NULL::uuid;
        END IF;
        UPDATE relay.agent_ceiling_holds h
          SET applied_at = now(), updated_at = now(),
            state = CASE WHEN v_expired THEN 'expired' ELSE h.state END
          WHERE h.tenant_id = v_tenant AND h.environment = v_env
            AND h.notification_id = v_hold.notification_id;
      END LOOP;
    END
    $fn$
    """
  end

  defp resume do
    ~S"""
    CREATE FUNCTION relay_fn.agent_resume(p_agent_ref uuid, p_decision_ref text,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS TABLE (result text, changed_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_created timestamptz;
      v_state relay.agent_run_states;
    BEGIN
      IF p_agent_ref IS NULL OR p_decision_ref IS NULL OR p_actor_ref IS NULL
        OR p_record_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-49';
      END IF;
      SELECT c.created_at INTO v_created FROM relay.agents c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_agent_ref;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'agent_not_found'::text, NULL::timestamptz;
        RETURN;
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['agent_ceiling', p_agent_ref::text]);
      SELECT * INTO v_state FROM relay.agent_run_states s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.agent_ref = p_agent_ref
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'unchanged'::text, v_created;
        RETURN;
      END IF;
      IF v_state.state = 'active' THEN
        RETURN QUERY SELECT 'unchanged'::text, v_state.changed_at;
        RETURN;
      END IF;
      UPDATE relay.agent_run_states s
        SET state = 'active', decision_ref = p_decision_ref, changed_at = now(),
          updated_at = now()
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.agent_ref = p_agent_ref;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'agent.resumed', p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'agent', p_agent_ref::text,
        p_decision_ref, p_record_digest);
      RETURN QUERY SELECT 'resumed'::text, now();
    END
    $fn$
    """
  end

  defp paused_deliveries_expire do
    ~S"""
    CREATE FUNCTION relay_fn.paused_deliveries_expire(p_limit integer) RETURNS bigint
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_limit integer := least(greatest(coalesce(p_limit, 500), 1), 5000);
      v_id uuid;
      v_count bigint := 0;
    BEGIN
      FOR v_id IN
        SELECT d.id FROM relay.deliveries d
        JOIN relay.notifications n ON n.tenant_id = d.tenant_id
          AND n.environment = d.environment AND n.id = d.notification_id
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.paused_at IS NOT NULL
          AND d.failure_kind IS NULL AND d.delivery_rank = 0 AND n.expires_at <= now()
          AND d.pause_rule_id NOT IN ('agent_ceiling.exceeded',
            'agent_ceiling.counter_unreadable')
        ORDER BY n.expires_at, d.id
        LIMIT v_limit
      LOOP
        IF relay_fn.delivery_expire(v_id, 'killswitch.paused_expired') = 'expired' THEN
          v_count := v_count + 1;
        END IF;
      END LOOP;
      RETURN v_count;
    END
    $fn$
    """
  end
end
