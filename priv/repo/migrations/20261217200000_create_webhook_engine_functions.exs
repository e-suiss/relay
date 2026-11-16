defmodule Relay.Repo.Migrations.CreateWebhookEngineFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @ts "timestamp with time zone"

  @functions [
    {"relay_fn.webhook_fan_out(uuid, jsonb, jsonb, bytea, uuid[], uuid[], #{@ts}[], #{@ts}[], #{@ts}, text, text, #{@ts})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_message_claim(uuid, uuid, #{@ts}, boolean, #{@ts})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.webhook_message_park(uuid, uuid, text, text, #{@ts}, #{@ts})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.webhook_endpoint_health_lock(uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_endpoint_health_save(uuid, jsonb, #{@ts})", "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_attempt_settle(uuid, uuid, uuid, jsonb, bytea, bytea, uuid, jsonb, #{@ts})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_messages_terminate(uuid[], text, text, text, #{@ts})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.webhook_messages_requeue(uuid[], #{@ts}[], #{@ts}[], text, #{@ts})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.webhook_endpoint_set_state(uuid, text, text, bytea, #{@actor}, #{@ts})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_endpoint_keys_destroyed(uuid[], #{@ts})", "relay_owner", ~w(relay_app)},
    {"relay_fn.webhook_retention_sweep(bigint, bigint, integer, #{@ts})", "relay_owner",
     ~w(relay_app)},
    {"relay_ops.webhook_due_scopes(#{@ts}, integer)", "relay_maint", ~w(relay_worker)}
  ]

  # WH-2
  # WH-10
  # WH-27
  # WH-28
  # WH-30
  # WH-31
  # WH-32
  # WH-35
  # WH-36
  # WH-37
  # INV-12
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp statements do
    [
      "ALTER TABLE relay.webhook_endpoint_health ADD COLUMN failing_clock_at timestamptz",
      "ALTER TABLE relay.webhook_endpoint_keys ADD COLUMN store_destroyed_at timestamptz",
      fan_out(),
      claim(),
      park(),
      health_lock(),
      health_save(),
      settle(),
      terminate(),
      requeue(),
      set_state(),
      keys_destroyed(),
      retention_sweep(),
      due_scopes()
    ]
  end

  defp fan_out do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_fan_out(p_event_id uuid, p_event jsonb, p_payload jsonb,
      p_payload_digest bytea, p_message_ids uuid[], p_endpoint_ids uuid[],
      p_next_attempt_ats timestamptz[], p_window_ends_ats timestamptz[],
      p_expires_at timestamptz, p_origin text, p_reason text, p_now timestamptz)
      RETURNS TABLE (message_id uuid, endpoint_id uuid, state text)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_event relay.webhook_events;
      v_endpoint relay.webhook_endpoints;
      v_health relay.webhook_endpoint_health;
      v_state text;
      v_hold text;
      v_count bigint;
    BEGIN
      IF p_event_id IS NULL OR p_message_ids IS NULL OR p_endpoint_ids IS NULL
        OR p_next_attempt_ats IS NULL OR p_window_ends_ats IS NULL OR p_origin IS NULL
        OR p_now IS NULL OR cardinality(p_message_ids) <> cardinality(p_endpoint_ids)
        OR cardinality(p_message_ids) <> cardinality(p_next_attempt_ats)
        OR cardinality(p_message_ids) <> cardinality(p_window_ends_ats) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-2';
      END IF;
      IF p_event IS NOT NULL THEN
        IF p_payload IS NULL OR p_payload_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-2';
        END IF;
        INSERT INTO relay.webhook_events (tenant_id, environment, id, use_kind, consumer_id,
          event_type, schema_version, origin, source, subject, stream_epoch, seq, occurred_at,
          traceparent, payload, payload_digest, created_at)
        VALUES (v_tenant, v_env, p_event_id, p_event ->> 'use_kind',
          (p_event ->> 'consumer_id')::uuid, p_event ->> 'event_type',
          COALESCE((p_event ->> 'schema_version')::bigint, 1), p_event ->> 'origin',
          p_event ->> 'source', p_event ->> 'subject', (p_event ->> 'stream_epoch')::bigint,
          (p_event ->> 'seq')::bigint, (p_event ->> 'occurred_at')::timestamptz,
          p_event ->> 'traceparent', p_payload, p_payload_digest, p_now)
        ON CONFLICT ON CONSTRAINT webhook_events_pkey DO NOTHING;
      END IF;
      SELECT * INTO v_event FROM relay.webhook_events e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_event_id;
      IF NOT FOUND THEN
        RETURN;
      END IF;
      FOR i IN 1 .. cardinality(p_message_ids) LOOP
        SELECT * INTO v_endpoint FROM relay.webhook_endpoints e
          WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_ids[i]
          FOR SHARE;
        CONTINUE WHEN NOT FOUND OR v_endpoint.state = 'archived';
        CONTINUE WHEN EXISTS (SELECT 1 FROM relay.webhook_messages m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env
            AND m.endpoint_id = p_endpoint_ids[i] AND m.event_id = p_event_id);
        SELECT * INTO v_health FROM relay.webhook_endpoint_health h
          WHERE h.tenant_id = v_tenant AND h.environment = v_env
            AND h.endpoint_id = p_endpoint_ids[i];
        v_hold := NULL;
        IF p_reason IS NOT NULL THEN
          v_state := 'dead_lettered';
        ELSIF v_endpoint.state = 'paused' THEN
          v_state := 'held';
          v_hold := 'endpoint_paused';
        ELSIF v_endpoint.state = 'disabled' THEN
          v_state := 'held';
          v_hold := 'endpoint_disabled';
        ELSIF v_health.breaker_state = 'open' AND v_health.breaker_retry_at > p_now THEN
          v_state := 'held';
          v_hold := 'breaker_open';
        ELSE
          v_state := 'pending';
        END IF;
        PERFORM relay_private.assert_new_id(p_message_ids[i]);
        INSERT INTO relay.webhook_messages (tenant_id, environment, id, endpoint_id, event_id,
          endpoint_version, event_type, origin, state, hold_reason, reason, schedule_no,
          schedule_started_at, attempt_count, total_attempt_count, retry_after_count,
          next_attempt_at, window_ends_at, expires_at, terminal_at, state_version, created_at,
          updated_at)
        VALUES (v_tenant, v_env, p_message_ids[i], p_endpoint_ids[i], p_event_id,
          v_endpoint.current_version, v_event.event_type, p_origin, v_state, v_hold, p_reason, 1,
          p_now, 0, 0, 0, CASE WHEN v_state = 'pending' THEN p_next_attempt_ats[i] END,
          p_window_ends_ats[i], p_expires_at,
          CASE WHEN v_state = 'dead_lettered' THEN p_now END, 1, p_now, p_now)
        ON CONFLICT ON CONSTRAINT webhook_messages_endpoint_event_key DO NOTHING;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        IF v_count = 1 THEN
          message_id := p_message_ids[i];
          endpoint_id := p_endpoint_ids[i];
          state := v_state;
          RETURN NEXT;
        END IF;
      END LOOP;
    END
    $fn$
    """
  end

  defp claim do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_message_claim(p_message_id uuid, p_lock_token uuid,
      p_locked_until timestamptz, p_manual boolean, p_now timestamptz)
      RETURNS TABLE (result text, next_attempt_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_messages;
      v_endpoint relay.webhook_endpoints;
      v_terminal boolean;
    BEGIN
      IF p_message_id IS NULL OR p_lock_token IS NULL OR p_locked_until IS NULL
        OR p_manual IS NULL OR p_now IS NULL OR p_locked_until <= p_now THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-32';
      END IF;
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::timestamptz;
        RETURN;
      END IF;
      SELECT * INTO v_row FROM relay.webhook_messages m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.locked_until IS NOT NULL AND v_row.locked_until > p_now THEN
        RETURN QUERY SELECT 'locked'::text, v_row.locked_until;
        RETURN;
      END IF;
      v_terminal := v_row.terminal_at IS NOT NULL;
      IF v_terminal AND NOT p_manual THEN
        RETURN QUERY SELECT 'terminal'::text, NULL::timestamptz;
        RETURN;
      END IF;
      SELECT * INTO v_endpoint FROM relay.webhook_endpoints e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = v_row.endpoint_id
        FOR SHARE;
      IF v_endpoint.state = 'archived' THEN
        IF NOT v_terminal THEN
          UPDATE relay.webhook_messages m SET state = 'dead_lettered', hold_reason = NULL,
              reason = 'endpoint_archived', next_attempt_at = NULL, locked_until = NULL,
              lock_token = NULL, terminal_at = p_now, state_version = m.state_version + 1,
              updated_at = p_now
            WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
        END IF;
        RETURN QUERY SELECT 'endpoint_archived'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF p_manual THEN
        IF v_endpoint.state <> 'active' THEN
          RETURN QUERY SELECT ('endpoint_' || v_endpoint.state)::text, NULL::timestamptz;
          RETURN;
        END IF;
        UPDATE relay.webhook_messages m SET locked_until = p_locked_until,
            lock_token = p_lock_token, updated_at = p_now
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
        RETURN QUERY SELECT 'claimed'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.expires_at IS NOT NULL AND v_row.expires_at <= p_now THEN
        UPDATE relay.webhook_messages m SET state = 'expired', hold_reason = NULL,
            reason = 'ttl_expired', next_attempt_at = NULL, locked_until = NULL,
            lock_token = NULL, terminal_at = p_now, state_version = m.state_version + 1,
            updated_at = p_now
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
        RETURN QUERY SELECT 'expired'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.window_ends_at IS NOT NULL AND v_row.window_ends_at <= p_now THEN
        UPDATE relay.webhook_messages m SET state = 'window_exceeded', hold_reason = NULL,
            reason = 'window_exceeded', next_attempt_at = NULL, locked_until = NULL,
            lock_token = NULL, terminal_at = p_now, state_version = m.state_version + 1,
            updated_at = p_now
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
        RETURN QUERY SELECT 'window_exceeded'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.state = 'held' THEN
        RETURN QUERY SELECT 'held'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_endpoint.state IN ('paused', 'disabled') THEN
        UPDATE relay.webhook_messages m SET state = 'held',
            hold_reason = 'endpoint_' || v_endpoint.state, next_attempt_at = NULL,
            locked_until = NULL, lock_token = NULL, state_version = m.state_version + 1,
            updated_at = p_now
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
        RETURN QUERY SELECT ('endpoint_' || v_endpoint.state)::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.state IN ('pending', 'scheduled') AND v_row.next_attempt_at > p_now THEN
        RETURN QUERY SELECT 'not_due'::text, v_row.next_attempt_at;
        RETURN;
      END IF;
      UPDATE relay.webhook_messages m SET state = 'in_flight', hold_reason = NULL,
          next_attempt_at = NULL, locked_until = p_locked_until, lock_token = p_lock_token,
          state_version = m.state_version + 1, updated_at = p_now
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
      RETURN QUERY SELECT 'claimed'::text, NULL::timestamptz;
    END
    $fn$
    """
  end

  defp park do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_message_park(p_message_id uuid, p_lock_token uuid,
      p_state text, p_hold_reason text, p_next_attempt_at timestamptz, p_now timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_messages;
    BEGIN
      IF p_message_id IS NULL OR p_lock_token IS NULL OR p_now IS NULL
        OR (p_state IS NOT NULL AND p_state NOT IN ('pending', 'scheduled', 'held'))
        OR (p_state = 'held') <> (p_hold_reason IS NOT NULL)
        OR (p_state IN ('pending', 'scheduled') AND p_next_attempt_at IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-38';
      END IF;
      SELECT * INTO v_row FROM relay.webhook_messages m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.lock_token IS DISTINCT FROM p_lock_token THEN
        RETURN 'lock_lost';
      END IF;
      IF p_state IS NULL OR v_row.terminal_at IS NOT NULL THEN
        UPDATE relay.webhook_messages m SET locked_until = NULL, lock_token = NULL,
            updated_at = p_now
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
        RETURN 'parked';
      END IF;
      UPDATE relay.webhook_messages m SET state = p_state, hold_reason = p_hold_reason,
          next_attempt_at = CASE WHEN p_state = 'held' THEN NULL ELSE p_next_attempt_at END,
          locked_until = NULL, lock_token = NULL, state_version = m.state_version + 1,
          updated_at = p_now
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
      RETURN 'parked';
    END
    $fn$
    """
  end

  defp health_lock do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_endpoint_health_lock(p_endpoint_id uuid)
      RETURNS SETOF relay.webhook_endpoint_health
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    BEGIN
      RETURN QUERY SELECT h.* FROM relay.webhook_endpoint_health h
        WHERE h.tenant_id = relay_private.ctx_tenant_id()
          AND h.environment = relay_private.ctx_environment()
          AND h.endpoint_id = p_endpoint_id
        FOR UPDATE;
    END
    $fn$
    """
  end

  defp health_save do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_endpoint_health_save(p_endpoint_id uuid, p_health jsonb,
      p_now timestamptz) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_count bigint;
    BEGIN
      IF p_endpoint_id IS NULL OR p_health IS NULL OR jsonb_typeof(p_health) <> 'object'
        OR p_now IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-35';
      END IF;
      UPDATE relay.webhook_endpoint_health h SET
          breaker_state = p_health ->> 'breaker_state',
          breaker_opened_at = (p_health ->> 'breaker_opened_at')::timestamptz,
          breaker_open_seconds = (p_health ->> 'breaker_open_seconds')::bigint,
          breaker_retry_at = (p_health ->> 'breaker_retry_at')::timestamptz,
          breaker_trips = (p_health ->> 'breaker_trips')::bigint,
          consecutive_failures = (p_health ->> 'consecutive_failures')::bigint,
          failing_since = (p_health ->> 'failing_since')::timestamptz,
          failure_count = (p_health ->> 'failure_count')::bigint,
          last_failure_at = (p_health ->> 'last_failure_at')::timestamptz,
          last_failure_code = p_health ->> 'last_failure_code',
          last_response_status = (p_health ->> 'last_response_status')::bigint,
          warned_at = (p_health ->> 'warned_at')::timestamptz,
          last_success_at = (p_health ->> 'last_success_at')::timestamptz,
          last_attempt_at = (p_health ->> 'last_attempt_at')::timestamptz,
          failing_clock_at = (p_health ->> 'failing_clock_at')::timestamptz,
          version = h.version + 1, updated_at = p_now
        WHERE h.tenant_id = relay_private.ctx_tenant_id()
          AND h.environment = relay_private.ctx_environment()
          AND h.endpoint_id = p_endpoint_id;
      GET DIAGNOSTICS v_count = ROW_COUNT;
      RETURN CASE WHEN v_count = 1 THEN 'saved' ELSE 'not_found' END;
    END
    $fn$
    """
  end

  defp settle do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_attempt_settle(p_message_id uuid, p_lock_token uuid,
      p_attempt_id uuid, p_attempt jsonb, p_body_digest bytea, p_response_ct bytea,
      p_response_key_id uuid, p_message jsonb, p_now timestamptz)
      RETURNS TABLE (result text, attempt_no bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_messages;
      v_no bigint;
      v_state text;
      v_terminal boolean;
    BEGIN
      IF p_message_id IS NULL OR p_lock_token IS NULL OR p_attempt_id IS NULL
        OR p_attempt IS NULL OR p_body_digest IS NULL OR p_now IS NULL
        OR (p_message IS NOT NULL AND jsonb_typeof(p_message) <> 'object') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-10';
      END IF;
      SELECT * INTO v_row FROM relay.webhook_messages m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      v_no := v_row.total_attempt_count + 1;
      PERFORM relay_private.assert_new_id(p_attempt_id);
      INSERT INTO relay.webhook_attempts (tenant_id, environment, id, created_at, message_id,
        endpoint_id, attempt_no, schedule_no, trigger_kind, started_at, finished_at, duration_ms,
        result, failure_code, response_status, retry_after_seconds, webhook_timestamp,
        body_digest, signature, destination_ip, destination_ref, response_ct, response_key_id,
        response_truncated, updated_at)
      VALUES (v_tenant, v_env, p_attempt_id, p_now, p_message_id, v_row.endpoint_id, v_no,
        v_row.schedule_no, p_attempt ->> 'trigger_kind',
        (p_attempt ->> 'started_at')::timestamptz, p_now,
        (p_attempt ->> 'duration_ms')::bigint, p_attempt ->> 'result',
        p_attempt ->> 'failure_code', (p_attempt ->> 'response_status')::bigint,
        (p_attempt ->> 'retry_after_seconds')::bigint,
        (p_attempt ->> 'webhook_timestamp')::bigint, p_body_digest, p_attempt ->> 'signature',
        (p_attempt ->> 'destination_ip')::inet, p_attempt ->> 'destination_ref', p_response_ct,
        p_response_key_id, COALESCE((p_attempt ->> 'response_truncated')::boolean, false), p_now);
      IF v_row.lock_token IS DISTINCT FROM p_lock_token THEN
        UPDATE relay.webhook_messages m SET total_attempt_count = v_no, last_attempt_at = p_now,
            updated_at = p_now
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
        RETURN QUERY SELECT 'lock_lost'::text, v_no;
        RETURN;
      END IF;
      IF p_message IS NULL THEN
        UPDATE relay.webhook_messages m SET total_attempt_count = v_no, last_attempt_at = p_now,
            last_response_status = (p_attempt ->> 'response_status')::bigint,
            locked_until = NULL, lock_token = NULL, updated_at = p_now
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
        RETURN QUERY SELECT 'settled'::text, v_no;
        RETURN;
      END IF;
      v_state := p_message ->> 'state';
      v_terminal := v_state IN ('delivered', 'failed_permanent', 'exhausted', 'expired',
        'window_exceeded', 'dead_lettered', 'cancelled');
      UPDATE relay.webhook_messages m SET state = v_state,
          hold_reason = p_message ->> 'hold_reason', reason = p_message ->> 'reason',
          attempt_count = (p_message ->> 'attempt_count')::bigint,
          total_attempt_count = v_no,
          retry_after_count = (p_message ->> 'retry_after_count')::bigint,
          next_attempt_at = (p_message ->> 'next_attempt_at')::timestamptz,
          window_ends_at = COALESCE((p_message ->> 'window_ends_at')::timestamptz,
            m.window_ends_at),
          last_attempt_at = p_now,
          last_response_status = (p_attempt ->> 'response_status')::bigint,
          delivered_at = CASE WHEN v_state = 'delivered' THEN p_now ELSE m.delivered_at END,
          terminal_at = CASE WHEN v_terminal THEN p_now END,
          locked_until = NULL, lock_token = NULL, state_version = m.state_version + 1,
          updated_at = p_now
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_id;
      RETURN QUERY SELECT 'settled'::text, v_no;
    END
    $fn$
    """
  end

  defp terminate do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_messages_terminate(p_message_ids uuid[], p_state text,
      p_reason text, p_actor_ref text, p_now timestamptz)
      RETURNS TABLE (message_id uuid, endpoint_id uuid, event_id uuid, attempt_count bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    BEGIN
      IF p_message_ids IS NULL OR p_now IS NULL OR p_reason IS NULL OR p_state IS NULL
        OR p_state NOT IN ('expired', 'window_exceeded', 'cancelled', 'dead_lettered') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-27';
      END IF;
      RETURN QUERY
        UPDATE relay.webhook_messages m SET state = p_state, hold_reason = NULL,
            reason = p_reason, next_attempt_at = NULL, locked_until = NULL, lock_token = NULL,
            terminal_at = p_now,
            cancelled_by_ref = CASE WHEN p_state = 'cancelled' THEN p_actor_ref END,
            state_version = m.state_version + 1, updated_at = p_now
          WHERE m.tenant_id = relay_private.ctx_tenant_id()
            AND m.environment = relay_private.ctx_environment()
            AND m.id = ANY (p_message_ids) AND m.terminal_at IS NULL
            AND (m.locked_until IS NULL OR m.locked_until <= p_now)
          RETURNING m.id, m.endpoint_id, m.event_id, m.total_attempt_count;
    END
    $fn$
    """
  end

  defp requeue do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_messages_requeue(p_message_ids uuid[],
      p_next_attempt_ats timestamptz[], p_window_ends_ats timestamptz[], p_mode text,
      p_now timestamptz)
      RETURNS TABLE (message_id uuid, endpoint_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_messages;
    BEGIN
      IF p_message_ids IS NULL OR p_next_attempt_ats IS NULL OR p_now IS NULL
        OR p_mode IS NULL OR p_mode NOT IN ('release', 'restart', 'rescue', 'nudge')
        OR cardinality(p_message_ids) <> cardinality(p_next_attempt_ats)
        OR (p_mode = 'restart' AND (p_window_ends_ats IS NULL
          OR cardinality(p_message_ids) <> cardinality(p_window_ends_ats))) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-32';
      END IF;
      FOR i IN 1 .. cardinality(p_message_ids) LOOP
        SELECT * INTO v_row FROM relay.webhook_messages m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_ids[i]
          FOR UPDATE;
        CONTINUE WHEN NOT FOUND;
        CONTINUE WHEN v_row.locked_until IS NOT NULL AND v_row.locked_until > p_now;
        IF p_mode = 'release' THEN
          CONTINUE WHEN v_row.state <> 'held';
          UPDATE relay.webhook_messages m SET
              state = CASE WHEN m.attempt_count = 0 THEN 'pending' ELSE 'scheduled' END,
              hold_reason = NULL, next_attempt_at = p_next_attempt_ats[i],
              state_version = m.state_version + 1, updated_at = p_now
            WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_ids[i];
        ELSIF p_mode = 'nudge' THEN
          CONTINUE WHEN v_row.state NOT IN ('pending', 'scheduled');
          UPDATE relay.webhook_messages m SET next_attempt_at = p_next_attempt_ats[i],
              updated_at = p_now
            WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_ids[i];
        ELSIF p_mode = 'rescue' THEN
          CONTINUE WHEN v_row.state <> 'in_flight';
          UPDATE relay.webhook_messages m SET
              state = CASE WHEN m.attempt_count = 0 THEN 'pending' ELSE 'scheduled' END,
              next_attempt_at = p_next_attempt_ats[i], locked_until = NULL, lock_token = NULL,
              state_version = m.state_version + 1, updated_at = p_now
            WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_ids[i];
        ELSE
          CONTINUE WHEN v_row.state IN ('delivered', 'in_flight');
          UPDATE relay.webhook_messages m SET state = 'pending', hold_reason = NULL,
              reason = NULL, schedule_no = m.schedule_no + 1, schedule_started_at = p_now,
              attempt_count = 0, retry_after_count = 0,
              next_attempt_at = p_next_attempt_ats[i], window_ends_at = p_window_ends_ats[i],
              locked_until = NULL, lock_token = NULL, terminal_at = NULL,
              cancelled_by_ref = NULL, state_version = m.state_version + 1, updated_at = p_now
            WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_message_ids[i];
        END IF;
        message_id := p_message_ids[i];
        endpoint_id := v_row.endpoint_id;
        RETURN NEXT;
      END LOOP;
    END
    $fn$
    """
  end

  defp set_state do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_endpoint_set_state(p_endpoint_id uuid, p_state text,
      p_reason text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
      p_on_behalf_of_ref text, p_access_record_ref text, p_now timestamptz)
      RETURNS TABLE (result text, version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.webhook_endpoints;
      v_version bigint;
    BEGIN
      IF p_endpoint_id IS NULL OR p_state IS NULL OR p_record_digest IS NULL OR p_now IS NULL
        OR p_state NOT IN ('active', 'paused', 'disabled')
        OR (p_state = 'disabled') <> (p_reason IS NOT NULL)
        OR (p_reason IS NOT NULL AND p_reason NOT IN ('failing', 'gone')) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-31';
      END IF;
      SELECT * INTO v_row FROM relay.webhook_endpoints e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_row.state = 'archived' THEN
        RETURN QUERY SELECT 'archived'::text, v_row.version;
        RETURN;
      END IF;
      IF v_row.state = p_state THEN
        RETURN QUERY SELECT 'unchanged'::text, v_row.version;
        RETURN;
      END IF;
      IF p_state <> 'disabled' AND v_row.managed_by = 'product' THEN
        RETURN QUERY SELECT 'managed'::text, v_row.version;
        RETURN;
      END IF;
      IF (p_state = 'paused' AND v_row.state <> 'active')
        OR (p_state = 'active' AND v_row.state <> 'paused') THEN
        RETURN QUERY SELECT 'invalid_state'::text, v_row.version;
        RETURN;
      END IF;
      UPDATE relay.webhook_endpoints e SET state = p_state,
          paused_at = CASE WHEN p_state = 'paused' THEN p_now END,
          disabled_at = CASE WHEN p_state = 'disabled' THEN p_now END,
          disabled_reason = p_reason, version = e.version + 1, updated_at = p_now
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_id
        RETURNING e.version INTO v_version;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_endpoint.updated',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_endpoint',
        p_endpoint_id::text, p_reason, p_record_digest);
      RETURN QUERY SELECT 'changed'::text, v_version;
    END
    $fn$
    """
  end

  defp keys_destroyed do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_endpoint_keys_destroyed(p_key_ids uuid[], p_now timestamptz)
      RETURNS bigint
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_count bigint;
    BEGIN
      IF p_key_ids IS NULL OR p_now IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-6';
      END IF;
      UPDATE relay.webhook_endpoint_keys k SET store_destroyed_at = p_now, updated_at = p_now
        WHERE k.tenant_id = relay_private.ctx_tenant_id()
          AND k.environment = relay_private.ctx_environment()
          AND k.id = ANY (p_key_ids) AND k.state = 'retired' AND k.store_destroyed_at IS NULL;
      GET DIAGNOSTICS v_count = ROW_COUNT;
      RETURN v_count;
    END
    $fn$
    """
  end

  defp retention_sweep do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_retention_sweep(p_message_days bigint,
      p_response_days bigint, p_limit integer, p_now timestamptz)
      RETURNS TABLE (responses bigint, payloads bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_responses bigint;
      v_payloads bigint;
    BEGIN
      IF p_message_days IS NULL OR p_message_days < 1 OR p_response_days IS NULL
        OR p_response_days < 1 OR p_limit IS NULL OR p_limit < 1 OR p_now IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-30';
      END IF;
      UPDATE relay.webhook_attempts a SET response_ct = NULL, response_erased_at = p_now,
          updated_at = p_now
        WHERE a.tenant_id = v_tenant AND a.environment = v_env
          AND (a.id, a.created_at) IN (SELECT x.id, x.created_at FROM relay.webhook_attempts x
            WHERE x.tenant_id = v_tenant AND x.environment = v_env
              AND x.response_ct IS NOT NULL
              AND x.created_at <= p_now - p_response_days * interval '1 day'
            LIMIT p_limit);
      GET DIAGNOSTICS v_responses = ROW_COUNT;
      UPDATE relay.webhook_events e SET payload = NULL, payload_ct = NULL,
          payload_erased_at = p_now
        WHERE e.tenant_id = v_tenant AND e.environment = v_env
          AND e.id IN (SELECT x.id FROM relay.webhook_events x
            WHERE x.tenant_id = v_tenant AND x.environment = v_env
              AND x.payload_erased_at IS NULL
              AND x.created_at <= p_now - p_message_days * interval '1 day'
            ORDER BY x.created_at LIMIT p_limit);
      GET DIAGNOSTICS v_payloads = ROW_COUNT;
      RETURN QUERY SELECT v_responses, v_payloads;
    END
    $fn$
    """
  end

  defp due_scopes do
    ~S"""
    CREATE FUNCTION relay_ops.webhook_due_scopes(p_now timestamptz, p_limit integer)
      RETURNS TABLE (tenant_id uuid, environment text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT DISTINCT m.tenant_id, m.environment::text
      FROM relay.webhook_messages m
      WHERE m.terminal_at IS NULL
        AND ((m.state IN ('pending', 'scheduled') AND m.next_attempt_at <= p_now)
          OR (m.state = 'in_flight' AND m.locked_until <= p_now)
          OR (m.state = 'held' AND (m.window_ends_at <= p_now OR m.expires_at <= p_now)))
      LIMIT GREATEST(COALESCE(p_limit, 100), 1)
    $fn$
    """
  end
end
