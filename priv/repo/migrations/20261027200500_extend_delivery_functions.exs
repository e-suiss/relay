defmodule Relay.Repo.Migrations.ExtendDeliveryFunctions do
  use Ecto.Migration

  @functions [
    {"relay_fn.delivery_gate(uuid)", ~w(relay_app)},
    {"relay_fn.delivery_pause(uuid, text, uuid)", ~w(relay_app)},
    {"relay_fn.delivery_resume(uuid, text, text)", ~w(relay_app)},
    {"relay_fn.delivery_hold(uuid, text, timestamp with time zone)", ~w(relay_app)},
    {"relay_fn.delivery_expire(uuid, text)", ~w(relay_app)}
  ]

  # TN-40
  # T-15 (5)
  # T-26
  # T-29 (6)
  # T-34 (3)
  # C-2
  # OP-3
  def up do
    execute(projection_apply())
    Enum.each(statements(), &execute/1)

    for {signature, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end

    execute("SET LOCAL ROLE relay_owner")
    execute(attempt_open())
    execute(projection_rebuild())
    execute("RESET ROLE")
  end

  defp projection_apply do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.projection_apply(p_state relay_private.delivery_projection,
      p_event_type text, p_attempt_no bigint, p_provider_seq bigint, p_occurred_at timestamptz,
      p_received_at timestamptz, p_delivery_rank smallint, p_failure_kind text,
      p_failure_class text, p_failure_rule_id text, p_failure_reason text,
      p_after_delivered text, p_other_attempt_delivered boolean)
      RETURNS relay_private.delivery_projection
    LANGUAGE plpgsql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    DECLARE
      s relay_private.delivery_projection := p_state;
      v_changed boolean := false;
      v_conflict boolean := false;
    BEGIN
      IF p_event_type = 'delivery.replay_opened' AND s.failure_kind IS NOT NULL THEN
        s.failure_kind := NULL;
        s.failure_class := NULL;
        s.failure_rule_id := NULL;
        s.failure_reason := NULL;
        s.failure_attempt_no := NULL;
        s.failure_provider_seq := NULL;
        s.failure_occurred_at := NULL;
        s.failure_received_at := NULL;
        v_changed := true;
      END IF;
      IF p_event_type IN ('delivery.queued', 'delivery.deferred') AND s.projection_version = 0 THEN
        v_changed := true;
      END IF;
      IF p_delivery_rank IS NOT NULL THEN
        IF p_delivery_rank > s.delivery_rank THEN
          s.delivery_rank := p_delivery_rank;
          IF s.accepted_at IS NULL THEN
            s.accepted_at := p_occurred_at;
          END IF;
          IF p_delivery_rank = 2 THEN
            s.delivered_at := p_occurred_at;
            IF s.failure_kind IN ('failed', 'bounced')
              AND s.failure_attempt_no IS NOT DISTINCT FROM p_attempt_no THEN
              s.failure_kind := NULL;
              s.failure_class := NULL;
              s.failure_rule_id := NULL;
              s.failure_reason := NULL;
              s.failure_attempt_no := NULL;
              s.failure_provider_seq := NULL;
              s.failure_occurred_at := NULL;
              s.failure_received_at := NULL;
            END IF;
          END IF;
          v_changed := true;
        ELSE
          s.late_event_count := s.late_event_count + 1;
        END IF;
        IF p_delivery_rank = 2 AND COALESCE(p_other_attempt_delivered, false)
          AND NOT s.duplicate_delivered THEN
          s.duplicate_delivered := true;
          v_changed := true;
        END IF;
      END IF;
      IF p_failure_kind IS NOT NULL AND (s.failure_kind IS NULL OR
        (COALESCE(p_attempt_no, 0), COALESCE(p_provider_seq, -1), p_occurred_at, p_received_at)
          > (COALESCE(s.failure_attempt_no, 0), COALESCE(s.failure_provider_seq, -1),
            s.failure_occurred_at, s.failure_received_at)) THEN
        IF s.delivery_rank = 2 AND COALESCE(p_after_delivered, 'stale') <> 'valid' THEN
          IF p_after_delivered = 'conflict' AND NOT s.has_conflict THEN
            s.has_conflict := true;
            v_conflict := true;
          END IF;
        ELSE
          s.failure_kind := p_failure_kind;
          s.failure_class := p_failure_class;
          s.failure_rule_id := p_failure_rule_id;
          s.failure_reason := p_failure_reason;
          s.failure_attempt_no := p_attempt_no;
          s.failure_provider_seq := p_provider_seq;
          s.failure_occurred_at := p_occurred_at;
          s.failure_received_at := p_received_at;
          v_changed := true;
        END IF;
      END IF;
      s.last_event_at := GREATEST(s.last_event_at, p_received_at);
      s.result := CASE
        WHEN v_changed THEN 'applied'
        WHEN v_conflict THEN 'conflict_flagged'
        ELSE 'stale_ignored'
      END;
      IF s.result <> 'stale_ignored' THEN
        s.projection_version := s.projection_version + 1;
      END IF;
      RETURN s;
    END
    $fn$
    """
  end

  defp attempt_open do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.attempt_open(p_id uuid, p_delivery_id uuid, p_provider text,
      p_provider_account_id uuid, p_provider_idempotency_key text)
      RETURNS TABLE (result text, attempt_no bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_delivery relay.deliveries;
      v_last_state text;
      v_no bigint;
    BEGIN
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::bigint;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      SELECT * INTO v_delivery FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'delivery_not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_delivery.decision = 'skip' OR v_delivery.failure_kind IS NOT NULL
        OR v_delivery.delivery_rank > 0
        OR (v_delivery.decision = 'defer' AND v_delivery.deferred_until > now()) THEN
        RETURN QUERY SELECT 'delivery_not_sendable'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_delivery.paused_at IS NOT NULL THEN
        RETURN QUERY SELECT 'delivery_paused'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_delivery.attempt_count > 0 THEN
        SELECT a.state INTO v_last_state FROM relay.delivery_attempts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.delivery_id = p_delivery_id
            AND a.attempt_no = v_delivery.attempt_count;
        IF v_last_state IN ('pending', 'in_flight') THEN
          RETURN QUERY SELECT 'attempt_active'::text, v_delivery.attempt_count;
          RETURN;
        END IF;
      END IF;
      UPDATE relay.deliveries d SET attempt_count = d.attempt_count + 1, updated_at = now()
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
        RETURNING d.attempt_count INTO v_no;
      INSERT INTO relay.delivery_attempts (tenant_id, environment, id, created_at, delivery_id,
        attempt_no, state, started_at, finished_at, provider, provider_account_id,
        provider_idempotency_key, provider_message_id, failure_class, raw_code, updated_at)
      VALUES (v_tenant, v_env, p_id, now(), p_delivery_id, v_no, 'pending', NULL, NULL,
        COALESCE(p_provider, v_delivery.provider),
        COALESCE(p_provider_account_id, v_delivery.provider_account_id),
        p_provider_idempotency_key, NULL, NULL, NULL, now());
      RETURN QUERY SELECT 'opened'::text, v_no;
    END
    $fn$
    """
  end

  defp projection_rebuild do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.delivery_projection_rebuild(p_delivery_id uuid)
      RETURNS TABLE (column_name text, stored text, rebuilt text)
    LANGUAGE plpgsql STABLE SECURITY INVOKER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_delivery relay.deliveries;
      s relay_private.delivery_projection := relay_private.projection_zero();
      e relay.delivery_events;
      v_effect jsonb;
      v_rank smallint;
      v_delivered bigint[] := ARRAY[]::bigint[];
      v_delivered_null boolean := false;
      v_other boolean;
      v_paused_at timestamptz;
      v_pause_rule_id text;
      v_pause_kill_switch_id uuid;
      v_replay_depth smallint := 0;
      v_replay_dead_letter_id uuid;
      v_replay_dead_letter_created_at timestamptz;
    BEGIN
      SELECT * INTO v_delivery FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
      IF NOT FOUND THEN
        RETURN;
      END IF;
      FOR e IN
        SELECT * FROM relay.delivery_events x
        WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.delivery_id = p_delivery_id
        ORDER BY x.received_at, x.id
      LOOP
        v_effect := COALESCE(e.detail -> 'effect', '{}'::jsonb);
        v_rank := (v_effect ->> 'delivery_rank')::smallint;
        v_other := false;
        IF v_rank = 2 THEN
          v_other := (e.attempt_no IS NULL AND cardinality(v_delivered) > 0)
            OR (e.attempt_no IS NOT NULL
              AND (v_delivered_null OR EXISTS (
                SELECT 1 FROM unnest(v_delivered) AS x(n) WHERE x.n <> e.attempt_no)));
        END IF;
        s := relay_private.projection_apply(s, e.event_type, e.attempt_no, e.provider_seq,
          e.occurred_at, e.received_at, v_rank, v_effect ->> 'failure_kind',
          v_effect ->> 'failure_class', v_effect ->> 'failure_rule_id',
          v_effect ->> 'failure_reason', v_effect ->> 'after_delivered', v_other);
        IF e.event_type = 'delivery.paused' THEN
          v_paused_at := e.occurred_at;
          v_pause_rule_id := e.detail ->> 'rule_id';
          v_pause_kill_switch_id := (e.detail ->> 'kill_switch_id')::uuid;
        ELSIF e.event_type = 'delivery.resumed' THEN
          v_paused_at := NULL;
          v_pause_rule_id := NULL;
          v_pause_kill_switch_id := NULL;
        ELSIF e.event_type = 'delivery.replay_opened' THEN
          v_replay_depth := 1;
          v_replay_dead_letter_id := (e.detail ->> 'dead_letter_id')::uuid;
          v_replay_dead_letter_created_at := (e.detail ->> 'dead_letter_created_at')::timestamptz;
        END IF;
        IF v_rank = 2 THEN
          IF e.attempt_no IS NULL THEN
            v_delivered_null := true;
          ELSE
            v_delivered := array_append(v_delivered, e.attempt_no);
          END IF;
        END IF;
      END LOOP;
      RETURN QUERY
        SELECT c.name, c.stored, c.rebuilt
        FROM (VALUES
          ('delivery_rank', v_delivery.delivery_rank::text, s.delivery_rank::text),
          ('accepted_at', v_delivery.accepted_at::text, s.accepted_at::text),
          ('delivered_at', v_delivery.delivered_at::text, s.delivered_at::text),
          ('failure_kind', v_delivery.failure_kind, s.failure_kind),
          ('failure_class', v_delivery.failure_class, s.failure_class),
          ('failure_rule_id', v_delivery.failure_rule_id, s.failure_rule_id),
          ('failure_reason', v_delivery.failure_reason, s.failure_reason),
          ('failure_attempt_no', v_delivery.failure_attempt_no::text, s.failure_attempt_no::text),
          ('failure_provider_seq', v_delivery.failure_provider_seq::text,
            s.failure_provider_seq::text),
          ('failure_occurred_at', v_delivery.failure_occurred_at::text,
            s.failure_occurred_at::text),
          ('failure_received_at', v_delivery.failure_received_at::text,
            s.failure_received_at::text),
          ('has_conflict', v_delivery.has_conflict::text, s.has_conflict::text),
          ('duplicate_delivered', v_delivery.duplicate_delivered::text,
            s.duplicate_delivered::text),
          ('late_event_count', v_delivery.late_event_count::text, s.late_event_count::text),
          ('projection_version', v_delivery.projection_version::text, s.projection_version::text),
          ('last_event_at', v_delivery.last_event_at::text, s.last_event_at::text),
          ('paused_at', v_delivery.paused_at::text, v_paused_at::text),
          ('pause_rule_id', v_delivery.pause_rule_id::text, v_pause_rule_id),
          ('pause_kill_switch_id', v_delivery.pause_kill_switch_id::text,
            v_pause_kill_switch_id::text),
          ('replay_depth', v_delivery.replay_depth::text, v_replay_depth::text),
          ('replay_dead_letter_id', v_delivery.replay_dead_letter_id::text,
            v_replay_dead_letter_id::text),
          ('replay_dead_letter_created_at', v_delivery.replay_dead_letter_created_at::text,
            v_replay_dead_letter_created_at::text)
        ) AS c(name, stored, rebuilt)
        WHERE c.stored IS DISTINCT FROM c.rebuilt;
    END
    $fn$
    """
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.delivery_gate(p_delivery_id uuid)
        RETURNS TABLE (result text, channel text, message_class text, subtenant_id uuid,
          provider_account_id uuid, notification_id uuid, expires_at timestamptz,
          attempt_count bigint)
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
        v_result text;
      BEGIN
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::text, NULL::text, NULL::uuid, NULL::uuid,
            NULL::uuid, NULL::timestamptz, NULL::bigint;
          RETURN;
        END IF;
        SELECT * INTO v_notification FROM relay.notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env
            AND n.id = v_delivery.notification_id;
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
          v_notification.expires_at, v_delivery.attempt_count;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.delivery_pause(p_delivery_id uuid, p_rule_id text,
        p_kill_switch_id uuid) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
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
        RETURN 'paused';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.delivery_resume(p_delivery_id uuid, p_decision_ref text,
        p_rule_id text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
        v_rule relay.rule_id := p_rule_id;
      BEGIN
        IF p_rule_id IS NULL OR p_decision_ref IS NULL
          OR char_length(p_decision_ref) NOT BETWEEN 1 AND 256 THEN
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
        IF v_delivery.paused_at IS NULL THEN
          RETURN 'not_paused';
        END IF;
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay', 'delivery.resumed',
          NULL, NULL, NULL, now(), NULL, NULL, NULL, NULL, NULL, NULL, NULL,
          jsonb_build_object('rule_id', v_rule, 'decision_ref', p_decision_ref),
          v_delivery.traceparent);
        UPDATE relay.deliveries d SET paused_at = NULL, pause_rule_id = NULL,
            pause_kill_switch_id = NULL, updated_at = now()
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
        RETURN 'resumed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.delivery_hold(p_delivery_id uuid, p_rule_id text,
        p_until timestamptz) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
        v_rule relay.rule_id := p_rule_id;
      BEGIN
        IF p_rule_id IS NULL OR p_until IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-34';
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
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay', 'delivery.held',
          NULL, NULL, NULL, now(), NULL, NULL, NULL, NULL, NULL, NULL, NULL,
          jsonb_build_object('rule_id', v_rule, 'until', p_until), v_delivery.traceparent);
        RETURN 'held';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.delivery_expire(p_delivery_id uuid, p_rule_id text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
        v_rule relay.rule_id := p_rule_id;
      BEGIN
        IF p_rule_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-26';
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
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery,
          NULLIF(v_delivery.attempt_count, 0), 'relay', 'delivery.expired', NULL, NULL, NULL,
          now(), NULL, NULL, 'expired', NULL, v_rule, NULL, NULL, NULL, v_delivery.traceparent);
        RETURN 'expired';
      END
      $fn$
      """
    ]
  end
end
