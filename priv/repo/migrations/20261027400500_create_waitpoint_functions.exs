defmodule Relay.Repo.Migrations.CreateWaitpointFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @time "timestamp with time zone"

  @functions [
    {"relay_private.waitpoint_lock(text, text)", "relay_migrator", ~w(relay_owner)},
    {"relay_private.waitpoint_emit(relay.waitpoints, text, uuid, uuid, bytea, uuid)",
     "relay_migrator", ~w(relay_owner)},
    {"relay_private.waitpoint_release(relay.waitpoints)", "relay_migrator", ~w(relay_owner)},
    {"relay_private.waitpoint_expire(relay.waitpoints, #{@time})", "relay_migrator",
     ~w(relay_owner)},
    {"relay_fn.waitpoint_open(uuid, text, text, uuid, uuid, text, text, jsonb, jsonb, uuid[], bytea, bytea, bytea, bytea, uuid, #{@time}, bigint, text, jsonb, text[], text[], bigint, bigint, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.waitpoint_event_offer(uuid, text, text, text, uuid, uuid, bytea, uuid, uuid, bytea)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.waitpoint_resolve_by_event(uuid, uuid, uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.waitpoint_respond(uuid, uuid, uuid, text, text, text, text, text, bytea, bytea, uuid, bytea, uuid)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.waitpoint_heartbeat(uuid, text, uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.waitpoint_timer_fire(uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.waitpoint_cancel(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.waitpoint_get(uuid)", "relay_owner", ~w(relay_app relay_report)},
    {"relay_fn.waitpoint_list(text[], text, uuid, text[], uuid, integer)", "relay_owner",
     ~w(relay_app relay_report)},
    {"relay_fn.waitpoint_due(integer)", "relay_owner", ~w(relay_app)},
    {"relay_ops.waitpoint_due_scopes(integer)", "relay_maint", ~w(relay_worker)}
  ]

  # C-72
  # C-73
  # C-8
  # T-24
  # AG-4
  # AG-9
  # AG-10
  # AG-11
  # AG-13
  # AG-14
  # AG-15
  # AG-16
  # AG-64
  # WF-43
  # INV-3
  # INV-12
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    private() ++ lifecycle() ++ reads()
  end

  defp private do
    [
      ~S"""
      CREATE FUNCTION relay_private.waitpoint_lock(p_event_type text, p_correlation_key text)
        RETURNS void
      LANGUAGE sql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT pg_advisory_xact_lock(hashtextextended(relay_private.ctx_tenant_id()::text || '/'
          || relay_private.ctx_environment()::text || '/' || p_event_type || '/'
          || p_correlation_key, 0))
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.waitpoint_emit(p_waitpoint relay.waitpoints,
        p_event_type text, p_record_id uuid, p_source_event_id uuid, p_payload_ct bytea,
        p_payload_key_id uuid)
        RETURNS bigint
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      DECLARE
        v_seq bigint;
      BEGIN
        SELECT a.seq INTO v_seq
          FROM relay_fn.mailbox_append(COALESCE(p_record_id, uuidv7()), p_waitpoint.waiter_mailbox_id,
            'waitpoint_event', p_event_type, NULL, p_waitpoint.id, p_source_event_id,
            CASE WHEN p_payload_key_id IS NOT NULL THEN p_payload_ct END, NULL,
            CASE WHEN p_payload_ct IS NOT NULL THEN p_payload_key_id END,
            sha256(convert_to(jsonb_build_object('waitpoint_id', p_waitpoint.id, 'event_type',
              p_event_type, 'state', p_waitpoint.state)::text, 'UTF8')),
            p_waitpoint.traceparent) a;
        PERFORM relay_fn.outbox_append(uuidv7(), p_event_type, 'waitpoint:' || p_waitpoint.id::text,
          jsonb_build_object('waitpoint_id', p_waitpoint.id, 'state', p_waitpoint.state,
            'mailbox_seq', v_seq),
          p_waitpoint.traceparent);
        RETURN v_seq;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.waitpoint_release(p_waitpoint relay.waitpoints) RETURNS void
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      BEGIN
        UPDATE relay.mailboxes m SET open_waitpoints = GREATEST(m.open_waitpoints - 1, 0),
            updated_at = now()
          WHERE m.tenant_id = p_waitpoint.tenant_id AND m.environment = p_waitpoint.environment
            AND m.id = p_waitpoint.waiter_mailbox_id;
        UPDATE relay.waitpoint_counters c SET open_count = GREATEST(c.open_count - 1, 0),
            updated_at = now()
          WHERE c.tenant_id = p_waitpoint.tenant_id AND c.environment = p_waitpoint.environment;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.waitpoint_expire(p_waitpoint relay.waitpoints,
        p_now timestamptz)
        RETURNS void
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      DECLARE
        v_row relay.waitpoints;
      BEGIN
        UPDATE relay.waitpoints w SET state = 'expired', expired_at = p_now, stalled_at = NULL,
            state_changed_at = p_now, version = w.version + 1, updated_at = now()
          WHERE w.tenant_id = p_waitpoint.tenant_id AND w.environment = p_waitpoint.environment
            AND w.id = p_waitpoint.id
          RETURNING * INTO v_row;
        PERFORM relay_private.waitpoint_release(v_row);
        PERFORM relay_private.waitpoint_emit(v_row, 'waitpoint.expired', NULL, NULL,
          v_row.default_response_ct, v_row.field_key_id);
      END
      $fn$
      """
    ]
  end

  defp lifecycle do
    [open(), offer(), resolve_by_event(), respond(), heartbeat(), timer_fire(), cancel()]
  end

  defp open do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_open(p_id uuid, p_kind text, p_waiter_kind text,
      p_waiter_ref uuid, p_mailbox_id uuid, p_match_event_type text, p_correlation_key text,
      p_condition jsonb, p_response_schema jsonb, p_responder_ids uuid[], p_subject_digest bytea,
      p_content_ct bytea, p_claim_text_ct bytea, p_default_response_ct bytea, p_field_key_id uuid,
      p_expires_at timestamptz, p_heartbeat_interval_ms bigint, p_escalation_policy_ref text,
      p_surface_policy jsonb, p_deliver_to_topics text[], p_tags text[], p_tenant_open_cap bigint,
      p_waiter_open_cap bigint, p_traceparent text)
      RETURNS TABLE (result text, waitpoint_id uuid, expires_at timestamptz, early_record_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := relay_private.business_now();
      v_responders uuid[] := ARRAY(SELECT DISTINCT x.rid
        FROM unnest(COALESCE(p_responder_ids, ARRAY[]::uuid[])) AS x(rid));
      v_row relay.waitpoints;
      v_mailbox_result text;
      v_mailbox uuid;
      v_mailbox_state text;
      v_count bigint;
      v_early uuid;
    BEGIN
      IF p_id IS NULL OR p_kind IS NULL OR p_waiter_kind IS NULL OR p_waiter_ref IS NULL
        OR p_match_event_type IS NULL OR p_correlation_key IS NULL
        OR p_tenant_open_cap IS NULL OR p_tenant_open_cap < 1
        OR p_waiter_open_cap IS NULL OR p_waiter_open_cap < 1
        OR (p_kind = 'event' AND cardinality(v_responders) > 0)
        OR array_position(v_responders, NULL) IS NOT NULL
        OR EXISTS (SELECT 1 FROM unnest(COALESCE(p_tags, ARRAY[]::text[])) AS t(tag)
          WHERE t.tag IS NULL OR t.tag !~ '^[a-z0-9_.:-]{1,64}$') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-9';
      END IF;
      SELECT * INTO v_row FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_id;
      IF FOUND THEN
        RETURN QUERY SELECT 'exists'::text, v_row.id, v_row.expires_at, NULL::uuid;
        RETURN;
      END IF;
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      IF p_expires_at IS NULL OR p_expires_at <= v_now OR p_expires_at > v_now + interval '30 days' THEN
        RETURN QUERY SELECT 'expires_invalid'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      IF p_condition IS NOT NULL THEN
        RETURN QUERY SELECT 'condition_unsupported'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.waitpoint_lock(p_match_event_type, p_correlation_key);
      IF p_waiter_kind = 'agent' AND NOT EXISTS (SELECT 1 FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_waiter_ref
          AND r.kind = 'agent' AND r.state = 'active') THEN
        RETURN QUERY SELECT 'waiter_not_found'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      SELECT e.result, e.mailbox_id INTO v_mailbox_result, v_mailbox
        FROM relay_fn.mailbox_ensure(COALESCE(p_mailbox_id, uuidv7()), p_waiter_kind,
          p_waiter_ref) e;
      SELECT m.state INTO v_mailbox_state FROM relay.mailboxes m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = v_mailbox
        FOR UPDATE;
      IF v_mailbox_result NOT IN ('created', 'exists') OR v_mailbox_state IS DISTINCT FROM 'active' THEN
        RETURN QUERY SELECT 'waiter_not_found'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      IF p_waiter_kind = 'agent' AND p_waiter_ref = ANY (v_responders) THEN
        RETURN QUERY SELECT 'responder_is_waiter'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      IF (p_kind IN ('question', 'review') AND cardinality(v_responders) = 0)
        OR EXISTS (SELECT 1 FROM unnest(v_responders) AS x(rid)
          WHERE NOT EXISTS (SELECT 1 FROM relay.recipients r
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = x.rid
              AND r.state = 'active')) THEN
        RETURN QUERY SELECT 'responder_not_found'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      IF EXISTS (SELECT 1 FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.waiter_kind = p_waiter_kind
          AND w.waiter_ref = p_waiter_ref AND w.match_event_type = p_match_event_type
          AND w.correlation_key = p_correlation_key AND w.state IN ('open', 'stalled')) THEN
        RETURN QUERY SELECT 'active_exists'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      INSERT INTO relay.waitpoint_counters AS c (tenant_id, environment, open_count, updated_at)
      VALUES (v_tenant, v_env, 0, now())
      ON CONFLICT (tenant_id, environment) DO NOTHING;
      SELECT c.open_count INTO v_count FROM relay.waitpoint_counters c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env
        FOR UPDATE;
      IF v_count + 1 > p_tenant_open_cap THEN
        RETURN QUERY SELECT 'limit_exceeded'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      SELECT m.open_waitpoints INTO v_count FROM relay.mailboxes m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = v_mailbox;
      IF v_count + 1 > p_waiter_open_cap THEN
        RETURN QUERY SELECT 'limit_exceeded'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      INSERT INTO relay.waitpoints (tenant_id, environment, id, kind, waiter_kind, waiter_ref,
        waiter_mailbox_id, match_event_type, correlation_key, condition, response_schema,
        subject_digest, content_ct, claim_text_ct, default_response_ct, field_key_id,
        escalation_policy_ref, surface_policy, deliver_to_topics, tags, opened_at, expires_at,
        heartbeat_interval_ms, heartbeat_due_at, state, state_changed_at, version, traceparent,
        created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_kind, p_waiter_kind, p_waiter_ref, v_mailbox,
        p_match_event_type, p_correlation_key, NULL, p_response_schema, p_subject_digest,
        p_content_ct, p_claim_text_ct, p_default_response_ct, p_field_key_id,
        p_escalation_policy_ref, p_surface_policy, COALESCE(p_deliver_to_topics, ARRAY[]::text[]),
        COALESCE(p_tags, ARRAY[]::text[]), v_now, p_expires_at, p_heartbeat_interval_ms,
        v_now + p_heartbeat_interval_ms * interval '1 millisecond', 'open', v_now, 1, p_traceparent,
        now(), now())
      RETURNING * INTO v_row;
      INSERT INTO relay.waitpoint_responders (tenant_id, environment, waitpoint_id, recipient_id,
        waiter_kind, waiter_ref, added_by, created_at)
      SELECT v_tenant, v_env, p_id, x.rid, p_waiter_kind, p_waiter_ref, 'creation', now()
      FROM unnest(v_responders) AS x(rid);
      UPDATE relay.waitpoint_counters c SET open_count = c.open_count + 1, updated_at = now()
        WHERE c.tenant_id = v_tenant AND c.environment = v_env;
      UPDATE relay.mailboxes m SET open_waitpoints = m.open_waitpoints + 1, updated_at = now()
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = v_mailbox;
      SELECT r.id INTO v_early FROM relay.mailbox_records r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.mailbox_id = v_mailbox
          AND r.kind = 'early_event' AND r.event_type = p_match_event_type
          AND r.correlation_key = p_correlation_key AND r.consumed_at IS NULL
        ORDER BY r.created_at, r.id
        LIMIT 1
        FOR UPDATE;
      PERFORM relay_private.waitpoint_emit(v_row, 'waitpoint.created', NULL, NULL, NULL, NULL);
      RETURN QUERY SELECT 'opened'::text, v_row.id, v_row.expires_at, v_early;
    END
    $fn$
    """
  end

  defp offer do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_event_offer(p_event_id uuid, p_event_type text,
      p_correlation_key text, p_waiter_kind text, p_waiter_ref uuid, p_record_id uuid,
      p_payload_ct bytea, p_payload_subject_key_id uuid, p_payload_tenant_key_id uuid,
      p_payload_digest bytea)
      RETURNS TABLE (result text, waitpoint_id uuid, record_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_id uuid;
      v_matched boolean := false;
      v_mailbox_result text;
      v_mailbox uuid;
      v_append text;
    BEGIN
      IF p_event_type IS NULL OR p_correlation_key IS NULL OR p_payload_digest IS NULL
        OR (p_waiter_kind IS NULL) <> (p_waiter_ref IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-14';
      END IF;
      PERFORM relay_private.waitpoint_lock(p_event_type, p_correlation_key);
      FOR v_id IN
        SELECT w.id FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env
          AND w.match_event_type = p_event_type AND w.correlation_key = p_correlation_key
          AND w.state IN ('open', 'stalled')
          AND (p_waiter_kind IS NULL OR (w.waiter_kind = p_waiter_kind AND w.waiter_ref = p_waiter_ref))
        ORDER BY w.id
        FOR UPDATE
      LOOP
        v_matched := true;
        result := 'matched';
        waitpoint_id := v_id;
        record_id := NULL;
        RETURN NEXT;
      END LOOP;
      IF v_matched THEN
        RETURN;
      END IF;
      IF p_waiter_kind IS NOT NULL AND p_record_id IS NOT NULL THEN
        SELECT e.result, e.mailbox_id INTO v_mailbox_result, v_mailbox
          FROM relay_fn.mailbox_ensure(uuidv7(), p_waiter_kind, p_waiter_ref) e;
        IF v_mailbox_result IN ('created', 'exists') THEN
          SELECT a.result INTO v_append
            FROM relay_fn.mailbox_append(p_record_id, v_mailbox, 'early_event', p_event_type,
              p_correlation_key, NULL, p_event_id, p_payload_ct, p_payload_subject_key_id,
              p_payload_tenant_key_id, p_payload_digest, NULL) a;
          IF v_append = 'appended' THEN
            RETURN QUERY SELECT 'buffered'::text, NULL::uuid, p_record_id;
            RETURN;
          END IF;
        END IF;
      END IF;
      INSERT INTO relay.waitpoint_unmatched_events (tenant_id, environment, id, created_at,
        source_event_id, event_type, correlation_key, waiter_kind, waiter_ref, waitpoint_id, rule_id,
        payload_digest)
      VALUES (v_tenant, v_env, uuidv7(), now(), p_event_id, p_event_type, p_correlation_key,
        p_waiter_kind, p_waiter_ref, NULL, 'waitpoint.no_match', p_payload_digest);
      RETURN QUERY SELECT 'unmatched'::text, NULL::uuid, NULL::uuid;
    END
    $fn$
    """
  end

  defp resolve_by_event do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_resolve_by_event(p_waitpoint_id uuid, p_record_id uuid,
      p_source_event_id uuid)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := relay_private.business_now();
      v_row relay.waitpoints;
      v_early relay.mailbox_records;
      v_notice uuid;
    BEGIN
      IF p_record_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-13';
      END IF;
      SELECT * INTO v_row FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.kind <> 'event' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-72';
      END IF;
      IF v_row.state NOT IN ('open', 'stalled') THEN
        RETURN 'already_terminal';
      END IF;
      IF v_now >= v_row.expires_at THEN
        PERFORM relay_private.waitpoint_expire(v_row, v_now);
        RETURN 'expired';
      END IF;
      SELECT * INTO v_early FROM relay.mailbox_records r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_record_id
          AND r.created_at BETWEEN uuid_extract_timestamp(p_record_id) - interval '5 minutes'
            AND uuid_extract_timestamp(p_record_id) + interval '5 minutes'
        FOR UPDATE;
      IF FOUND THEN
        IF v_early.kind <> 'early_event' OR v_early.consumed_at IS NOT NULL
          OR v_early.mailbox_id <> v_row.waiter_mailbox_id
          OR v_early.event_type <> v_row.match_event_type
          OR v_early.correlation_key <> v_row.correlation_key THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-13';
        END IF;
        UPDATE relay.mailbox_records r SET consumed_by_waitpoint_id = p_waitpoint_id,
            consumed_at = now(), updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_record_id
            AND r.created_at = v_early.created_at;
        v_notice := uuidv7();
      ELSE
        v_notice := p_record_id;
      END IF;
      UPDATE relay.waitpoints w SET state = 'resolved', resolved_at = v_now,
          resolved_by_record_id = p_record_id,
          resolved_by_event_id = COALESCE(p_source_event_id, v_early.source_event_id),
          stalled_at = NULL, state_changed_at = v_now, version = w.version + 1, updated_at = now()
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        RETURNING * INTO v_row;
      PERFORM relay_private.waitpoint_release(v_row);
      PERFORM relay_private.waitpoint_emit(v_row, 'waitpoint.resolved', v_notice,
        COALESCE(p_source_event_id, v_early.source_event_id), NULL, NULL);
      RETURN 'resolved';
    END
    $fn$
    """
  end

  defp respond do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_respond(p_waitpoint_id uuid, p_response_id uuid,
      p_responder_recipient_id uuid, p_responder_actor_ref text, p_session_actor_ref text,
      p_via text, p_evidence_level text, p_evidence_ref text, p_subject_digest bytea,
      p_value_ct bytea, p_value_key_id uuid, p_value_digest bytea, p_source_record_id uuid)
      RETURNS TABLE (result text, response_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := relay_private.business_now();
      v_row relay.waitpoints;
      v_early relay.mailbox_records;
      v_reason text;
    BEGIN
      IF p_responder_recipient_id IS NULL OR p_responder_actor_ref IS NULL
        OR p_session_actor_ref IS NULL OR p_subject_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-11';
      END IF;
      SELECT * INTO v_row FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      IF v_row.kind = 'event' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-72';
      END IF;
      IF p_source_record_id IS NOT NULL THEN
        SELECT * INTO v_early FROM relay.mailbox_records r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_source_record_id
            AND r.created_at BETWEEN uuid_extract_timestamp(p_source_record_id) - interval '5 minutes'
              AND uuid_extract_timestamp(p_source_record_id) + interval '5 minutes'
          FOR UPDATE;
        IF NOT FOUND OR v_early.kind <> 'early_event' OR v_early.consumed_at IS NOT NULL
          OR v_early.mailbox_id <> v_row.waiter_mailbox_id THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-13';
        END IF;
        UPDATE relay.mailbox_records r SET consumed_by_waitpoint_id = p_waitpoint_id,
            consumed_at = now(), updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_source_record_id
            AND r.created_at = v_early.created_at;
      END IF;
      IF v_row.state NOT IN ('open', 'stalled') THEN
        v_reason := 'closed';
      ELSIF v_now >= v_row.expires_at THEN
        PERFORM relay_private.waitpoint_expire(v_row, v_now);
        SELECT * INTO v_row FROM relay.waitpoints w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id;
        v_reason := 'expired';
      ELSIF v_row.waiter_kind = 'agent' AND p_responder_recipient_id = v_row.waiter_ref THEN
        v_reason := 'is_waiter';
      ELSIF NOT EXISTS (SELECT 1 FROM relay.waitpoint_responders s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.waitpoint_id = p_waitpoint_id
          AND s.recipient_id = p_responder_recipient_id) THEN
        v_reason := 'not_responder';
      ELSIF p_responder_actor_ref <> p_session_actor_ref THEN
        v_reason := 'session_mismatch';
      ELSIF p_subject_digest <> v_row.subject_digest THEN
        v_reason := 'digest_mismatch';
      END IF;
      IF v_reason IS NOT NULL THEN
        INSERT INTO relay.waitpoint_response_rejections (tenant_id, environment, id, created_at,
          waitpoint_id, responder_recipient_id, responder_actor_ref, reason, rule_id, value_digest,
          responded_at)
        VALUES (v_tenant, v_env, uuidv7(), now(), p_waitpoint_id,
          (SELECT r.id FROM relay.recipients r WHERE r.tenant_id = v_tenant
            AND r.environment = v_env AND r.id = p_responder_recipient_id),
          p_responder_actor_ref, v_reason, ('waitpoint.response_' || v_reason)::relay.rule_id,
          p_value_digest, v_now);
        PERFORM relay_private.waitpoint_emit(v_row, 'waitpoint.response_rejected', NULL, NULL, NULL,
          NULL);
        RETURN QUERY SELECT CASE v_reason
            WHEN 'closed' THEN 'rejected_closed'
            WHEN 'expired' THEN 'rejected_expired'
            WHEN 'is_waiter' THEN 'rejected_is_waiter'
            WHEN 'not_responder' THEN 'rejected_not_responder'
            WHEN 'session_mismatch' THEN 'rejected_session_mismatch'
            ELSE 'rejected_digest_mismatch' END,
          NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_response_id);
      INSERT INTO relay.waitpoint_responses (tenant_id, environment, id, waitpoint_id, waiter_kind,
        waiter_ref, responder_recipient_id, responder_actor_ref, session_actor_ref, via,
        evidence_level, evidence_ref, subject_digest, value_ct, value_key_id, value_digest,
        source_record_id, responded_at, created_at)
      VALUES (v_tenant, v_env, p_response_id, p_waitpoint_id, v_row.waiter_kind, v_row.waiter_ref,
        p_responder_recipient_id, p_responder_actor_ref, p_session_actor_ref, p_via,
        p_evidence_level, p_evidence_ref, p_subject_digest, p_value_ct, p_value_key_id,
        p_value_digest, p_source_record_id, v_now, now());
      UPDATE relay.waitpoints w SET state = 'resolved', resolved_at = v_now,
          resolution_response_id = p_response_id, stalled_at = NULL, state_changed_at = v_now,
          version = w.version + 1, updated_at = now()
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        RETURNING * INTO v_row;
      PERFORM relay_private.waitpoint_release(v_row);
      PERFORM relay_private.waitpoint_emit(v_row, 'waitpoint.resolved', NULL, NULL, NULL, NULL);
      RETURN QUERY SELECT 'resolved'::text, p_response_id;
    END
    $fn$
    """
  end

  defp heartbeat do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_heartbeat(p_waitpoint_id uuid, p_waiter_kind text,
      p_waiter_ref uuid)
      RETURNS TABLE (result text, heartbeat_due_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := relay_private.business_now();
      v_row relay.waitpoints;
      v_due timestamptz;
    BEGIN
      SELECT * INTO v_row FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.waiter_kind IS DISTINCT FROM p_waiter_kind
        OR v_row.waiter_ref IS DISTINCT FROM p_waiter_ref THEN
        RETURN QUERY SELECT 'not_waiter'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.state NOT IN ('open', 'stalled') THEN
        RETURN QUERY SELECT 'already_terminal'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_now >= v_row.expires_at THEN
        PERFORM relay_private.waitpoint_expire(v_row, v_now);
        RETURN QUERY SELECT 'already_terminal'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.heartbeat_interval_ms IS NULL THEN
        RETURN QUERY SELECT 'no_heartbeat'::text, NULL::timestamptz;
        RETURN;
      END IF;
      v_due := v_now + v_row.heartbeat_interval_ms * interval '1 millisecond';
      UPDATE relay.waitpoints w SET heartbeat_due_at = v_due, state = 'open', stalled_at = NULL,
          state_changed_at = CASE WHEN w.state = 'stalled' THEN v_now ELSE w.state_changed_at END,
          version = w.version + 1, updated_at = now()
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id;
      RETURN QUERY SELECT CASE WHEN v_row.state = 'stalled' THEN 'reopened' ELSE 'renewed' END,
        v_due;
    END
    $fn$
    """
  end

  defp timer_fire do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_timer_fire(p_waitpoint_id uuid)
      RETURNS TABLE (result text, next_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := relay_private.business_now();
      v_row relay.waitpoints;
    BEGIN
      SELECT * INTO v_row FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.state NOT IN ('open', 'stalled') THEN
        RETURN QUERY SELECT 'already_terminal'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_now >= v_row.expires_at THEN
        PERFORM relay_private.waitpoint_expire(v_row, v_now);
        RETURN QUERY SELECT 'expired'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.state = 'open' AND v_row.heartbeat_due_at <= v_now THEN
        UPDATE relay.waitpoints w SET state = 'stalled', stalled_at = v_now, state_changed_at = v_now,
            version = w.version + 1, updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
          RETURNING * INTO v_row;
        PERFORM relay_private.waitpoint_emit(v_row, 'waitpoint.stalled', NULL, NULL, NULL, NULL);
        RETURN QUERY SELECT 'stalled'::text, v_row.expires_at;
        RETURN;
      END IF;
      IF v_row.state = 'open' AND v_row.next_escalation_at <= v_now THEN
        RETURN QUERY SELECT 'escalation_due'::text,
          least(v_row.expires_at, COALESCE(v_row.heartbeat_due_at, 'infinity'));
        RETURN;
      END IF;
      RETURN QUERY SELECT 'not_due'::text, CASE WHEN v_row.state = 'open'
        THEN least(v_row.expires_at, COALESCE(v_row.heartbeat_due_at, 'infinity'),
          COALESCE(v_row.next_escalation_at, 'infinity'))
        ELSE v_row.expires_at END;
    END
    $fn$
    """
  end

  defp cancel do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_cancel(p_waitpoint_id uuid, p_reason text,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := relay_private.business_now();
      v_row relay.waitpoints;
    BEGIN
      IF p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 1 AND 200 OR p_actor_kind IS NULL
        OR p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-72';
      END IF;
      SELECT * INTO v_row FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_row.state NOT IN ('open', 'stalled') THEN
        RETURN 'already_terminal';
      END IF;
      UPDATE relay.waitpoints w SET state = 'cancelled', cancelled_at = v_now,
          cancel_reason = p_reason, cancelled_by_ref = p_actor_ref, stalled_at = NULL,
          state_changed_at = v_now, version = w.version + 1, updated_at = now()
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        RETURNING * INTO v_row;
      PERFORM relay_private.waitpoint_release(v_row);
      PERFORM relay_private.waitpoint_emit(v_row, 'waitpoint.cancelled', NULL, NULL, NULL, NULL);
      IF p_actor_kind IN ('operator', 'installation_operator') THEN
        PERFORM relay_private.audit_write(v_tenant, v_env, 'waitpoint.cancelled', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'waitpoint', p_waitpoint_id::text,
          p_reason, p_record_digest);
      END IF;
      RETURN 'cancelled';
    END
    $fn$
    """
  end

  defp reads do
    [
      ~S"""
      CREATE FUNCTION relay_fn.waitpoint_get(p_waitpoint_id uuid)
        RETURNS SETOF relay.waitpoints
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT * FROM relay.waitpoints w
        WHERE w.tenant_id = relay_private.ctx_tenant_id()
          AND w.environment = relay_private.ctx_environment() AND w.id = p_waitpoint_id
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.waitpoint_list(p_states text[], p_waiter_kind text,
        p_waiter_ref uuid, p_tags text[], p_after_id uuid, p_limit integer)
        RETURNS SETOF relay.waitpoints
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT * FROM relay.waitpoints w
        WHERE w.tenant_id = relay_private.ctx_tenant_id()
          AND w.environment = relay_private.ctx_environment()
          AND (p_states IS NULL OR w.state = ANY (p_states))
          AND (p_waiter_kind IS NULL OR (w.waiter_kind = p_waiter_kind AND w.waiter_ref = p_waiter_ref))
          AND (p_tags IS NULL OR w.tags @> p_tags)
          AND (p_after_id IS NULL OR w.id > p_after_id)
        ORDER BY w.id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.waitpoint_due(p_limit integer)
        RETURNS TABLE (waitpoint_id uuid, due_at timestamptz)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT w.id, least(w.expires_at, coalesce(w.heartbeat_due_at, 'infinity'),
          coalesce(w.next_escalation_at, 'infinity'))
        FROM relay.waitpoints w
        WHERE w.tenant_id = relay_private.ctx_tenant_id()
          AND w.environment = relay_private.ctx_environment()
          AND w.state IN ('open', 'stalled')
          AND least(w.expires_at, coalesce(w.heartbeat_due_at, 'infinity'),
            coalesce(w.next_escalation_at, 'infinity')) <= relay_private.business_now()
          AND (w.state = 'open' OR w.expires_at <= relay_private.business_now())
        ORDER BY 2, 1
        LIMIT GREATEST(COALESCE(p_limit, 100), 1)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.waitpoint_due_scopes(p_limit integer)
        RETURNS TABLE (tenant_id uuid, environment text)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT DISTINCT w.tenant_id, w.environment::text
        FROM relay.waitpoints w
        LEFT JOIN relay.virtual_clocks v ON v.tenant_id = w.tenant_id
          AND v.environment = w.environment
        WHERE w.state IN ('open', 'stalled')
          AND least(w.expires_at, coalesce(w.heartbeat_due_at, 'infinity'),
            coalesce(w.next_escalation_at, 'infinity'))
            <= now() + coalesce(v.offset_ms, 0) * interval '1 millisecond'
          AND (w.state = 'open'
            OR w.expires_at <= now() + coalesce(v.offset_ms, 0) * interval '1 millisecond')
        LIMIT GREATEST(COALESCE(p_limit, 100), 1)
      $fn$
      """
    ]
  end
end
