defmodule Relay.Repo.Migrations.MatchWaitpointsByCorrelationDigest do
  use Ecto.Migration

  @time "timestamp with time zone"

  @old_owned [
    "relay_fn.mailbox_append(uuid, uuid, text, text, text, uuid, uuid, bytea, uuid, uuid, bytea, text)",
    "relay_fn.waitpoint_open(uuid, text, text, uuid, uuid, text, text, jsonb, jsonb, uuid[], bytea, bytea, bytea, bytea, uuid, #{@time}, bigint, text, jsonb, text[], text[], bigint, bigint, text)",
    "relay_fn.waitpoint_event_offer(uuid, text, text, text, uuid, uuid, bytea, uuid, uuid, bytea)",
    "relay_fn.waitpoint_resolve_by_event(uuid, uuid, uuid)"
  ]

  @functions [
    {"relay_private.waitpoint_lock(bytea[])", "relay_migrator", ~w(relay_owner)},
    {"relay_fn.mailbox_append(uuid, uuid, text, text, bytea, uuid, uuid, bytea, uuid, uuid, bytea, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.waitpoint_open(uuid, text, text, uuid, uuid, text, bytea[], jsonb, jsonb, uuid[], bytea, bytea, bytea, bytea, uuid, #{@time}, bigint, text, jsonb, text[], text[], bigint, bigint, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.waitpoint_event_offer(uuid, text, bytea[], text, uuid, uuid, bytea, uuid, uuid, bytea)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.waitpoint_resolve_by_event(uuid, uuid, uuid, bytea[])", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.correlation_plain_batch(integer)", "relay_owner", ~w(relay_app)},
    {"relay_fn.correlation_digest_fill(text[], uuid[], #{@time}[], bytea[])", "relay_owner",
     ~w(relay_app)}
  ]

  # AG-65
  # AG-11
  # AG-13
  # AG-14
  # WF-12
  # C-68
  # C-72
  # INV-12
  def up do
    execute("SET LOCAL ROLE relay_owner")
    Enum.each(@old_owned, &execute("DROP FUNCTION #{&1}"))
    execute("RESET ROLE")
    execute("DROP FUNCTION relay_private.waitpoint_lock(text, text)")
    Enum.each([lock(), append(), open(), offer(), resolve_by_event(), plain(), fill()], &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp lock do
    ~S"""
    CREATE FUNCTION relay_private.waitpoint_lock(p_correlation_digests bytea[]) RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    DECLARE
      v_digest bytea;
    BEGIN
      FOR v_digest IN
        SELECT DISTINCT d.digest FROM unnest(p_correlation_digests) AS d(digest) ORDER BY d.digest
      LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended(relay_private.ctx_tenant_id()::text || '/'
          || relay_private.ctx_environment()::text || '/' || encode(v_digest, 'hex'), 0));
      END LOOP;
    END
    $fn$
    """
  end

  defp append do
    ~S"""
    CREATE FUNCTION relay_fn.mailbox_append(p_id uuid, p_mailbox_id uuid, p_kind text,
      p_event_type text, p_correlation_digest bytea, p_waitpoint_id uuid, p_source_event_id uuid,
      p_payload_ct bytea, p_payload_subject_key_id uuid, p_payload_tenant_key_id uuid,
      p_payload_digest bytea, p_traceparent text)
      RETURNS TABLE (result text, epoch bigint, seq bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_state text;
      v_stream text;
      v_epoch bigint;
      v_seq bigint;
    BEGIN
      PERFORM relay_private.assert_new_id(p_id);
      IF p_kind IS NULL OR p_event_type IS NULL OR p_payload_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-68';
      END IF;
      SELECT m.state, m.stream_key INTO v_state, v_stream FROM relay.mailboxes m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mailbox_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'mailbox_not_found'::text, NULL::bigint, NULL::bigint;
        RETURN;
      END IF;
      IF v_state <> 'active' THEN
        RETURN QUERY SELECT 'mailbox_inactive'::text, NULL::bigint, NULL::bigint;
        RETURN;
      END IF;
      SELECT o.epoch, o.seq INTO v_epoch, v_seq
        FROM relay_fn.outbox_append(uuidv7(), 'mailbox.record_appended', v_stream,
          jsonb_build_object('mailbox_id', p_mailbox_id, 'record_id', p_id, 'kind', p_kind),
          p_traceparent) o;
      INSERT INTO relay.mailbox_records (tenant_id, environment, id, created_at, mailbox_id, epoch,
        seq, kind, event_type, correlation_digest, waitpoint_id, source_event_id, payload_ct,
        payload_subject_key_id, payload_tenant_key_id, payload_digest, delivery_state,
        delivery_count, traceparent, updated_at)
      VALUES (v_tenant, v_env, p_id, now(), p_mailbox_id, v_epoch, v_seq, p_kind, p_event_type,
        p_correlation_digest, p_waitpoint_id, p_source_event_id, p_payload_ct,
        p_payload_subject_key_id, p_payload_tenant_key_id, p_payload_digest,
        CASE WHEN p_kind = 'early_event' THEN 'held' ELSE 'available' END, 0, p_traceparent,
        now());
      RETURN QUERY SELECT 'appended'::text, v_epoch, v_seq;
    END
    $fn$
    """
  end

  defp open do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_open(p_id uuid, p_kind text, p_waiter_kind text,
      p_waiter_ref uuid, p_mailbox_id uuid, p_match_event_type text, p_correlation_digests bytea[],
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
        OR p_match_event_type IS NULL OR p_correlation_digests IS NULL
        OR cardinality(p_correlation_digests) < 1
        OR EXISTS (SELECT 1 FROM unnest(p_correlation_digests) AS d(digest)
          WHERE d.digest IS NULL OR octet_length(d.digest) <> 32)
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
      IF p_condition IS NOT NULL AND (p_waiter_kind <> 'subscriber' OR p_kind <> 'event') THEN
        RETURN QUERY SELECT 'condition_unsupported'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.waitpoint_lock(p_correlation_digests);
      IF p_waiter_kind IN ('agent', 'subscriber') AND NOT EXISTS (SELECT 1 FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_waiter_ref
          AND r.kind = p_waiter_kind AND r.state = 'active') THEN
        RETURN QUERY SELECT 'waiter_not_found'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      SELECT e.result, e.mailbox_id INTO v_mailbox_result, v_mailbox
        FROM relay_fn.mailbox_ensure(COALESCE(p_mailbox_id, uuidv7()), p_waiter_kind,
          p_waiter_ref) e;
      SELECT m.state INTO v_mailbox_state FROM relay.mailboxes m
        WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = v_mailbox
        FOR NO KEY UPDATE;
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
          AND w.correlation_digest = ANY (p_correlation_digests)
          AND w.state IN ('open', 'stalled')) THEN
        RETURN QUERY SELECT 'active_exists'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      INSERT INTO relay.waitpoint_counters AS c (tenant_id, environment, open_count, updated_at)
      VALUES (v_tenant, v_env, 0, now())
      ON CONFLICT (tenant_id, environment) DO NOTHING;
      SELECT c.open_count INTO v_count FROM relay.waitpoint_counters c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env
        FOR NO KEY UPDATE;
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
        waiter_mailbox_id, match_event_type, correlation_digest, condition, response_schema,
        subject_digest, content_ct, claim_text_ct, default_response_ct, field_key_id,
        escalation_policy_ref, surface_policy, deliver_to_topics, tags, opened_at, expires_at,
        heartbeat_interval_ms, heartbeat_due_at, state, state_changed_at, version, traceparent,
        created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_kind, p_waiter_kind, p_waiter_ref, v_mailbox,
        p_match_event_type, p_correlation_digests[1], p_condition, p_response_schema,
        p_subject_digest, p_content_ct, p_claim_text_ct, p_default_response_ct, p_field_key_id,
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
          AND r.consumed_at IS NULL AND r.correlation_digest = ANY (p_correlation_digests)
        ORDER BY r.created_at, r.id
        LIMIT 1
        FOR NO KEY UPDATE;
      PERFORM relay_private.waitpoint_emit(v_row, 'waitpoint.created', NULL, NULL, NULL, NULL);
      RETURN QUERY SELECT 'opened'::text, v_row.id, v_row.expires_at, v_early;
    END
    $fn$
    """
  end

  defp offer do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_event_offer(p_event_id uuid, p_event_type text,
      p_correlation_digests bytea[], p_waiter_kind text, p_waiter_ref uuid, p_record_id uuid,
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
      IF p_event_type IS NULL OR p_correlation_digests IS NULL
        OR cardinality(p_correlation_digests) < 1
        OR EXISTS (SELECT 1 FROM unnest(p_correlation_digests) AS d(digest)
          WHERE d.digest IS NULL OR octet_length(d.digest) <> 32)
        OR p_payload_digest IS NULL
        OR (p_waiter_kind IS NULL) <> (p_waiter_ref IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-14';
      END IF;
      PERFORM relay_private.waitpoint_lock(p_correlation_digests);
      FOR v_id IN
        SELECT w.id FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env
          AND w.match_event_type = p_event_type
          AND w.correlation_digest = ANY (p_correlation_digests)
          AND w.state IN ('open', 'stalled')
          AND (p_waiter_kind IS NULL OR (w.waiter_kind = p_waiter_kind AND w.waiter_ref = p_waiter_ref))
        ORDER BY w.id
        FOR NO KEY UPDATE
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
              p_correlation_digests[1], NULL, p_event_id, p_payload_ct, p_payload_subject_key_id,
              p_payload_tenant_key_id, p_payload_digest, NULL) a;
          IF v_append = 'appended' THEN
            RETURN QUERY SELECT 'buffered'::text, NULL::uuid, p_record_id;
            RETURN;
          END IF;
        END IF;
      END IF;
      INSERT INTO relay.waitpoint_unmatched_events (tenant_id, environment, id, created_at,
        source_event_id, event_type, correlation_digest, waiter_kind, waiter_ref, waitpoint_id,
        rule_id, payload_digest)
      VALUES (v_tenant, v_env, uuidv7(), now(), p_event_id, p_event_type, p_correlation_digests[1],
        CASE WHEN p_waiter_kind <> 'subscriber' THEN p_waiter_kind END,
        CASE WHEN p_waiter_kind <> 'subscriber' THEN p_waiter_ref END, NULL, 'waitpoint.no_match',
        p_payload_digest);
      RETURN QUERY SELECT 'unmatched'::text, NULL::uuid, NULL::uuid;
    END
    $fn$
    """
  end

  defp resolve_by_event do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_resolve_by_event(p_waitpoint_id uuid, p_record_id uuid,
      p_source_event_id uuid, p_correlation_digests bytea[])
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
      v_digests bytea[];
      v_notice uuid;
    BEGIN
      IF p_record_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-13';
      END IF;
      SELECT * INTO v_row FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        FOR NO KEY UPDATE;
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
        FOR NO KEY UPDATE;
      IF FOUND THEN
        v_digests := COALESCE(p_correlation_digests, ARRAY[v_row.correlation_digest]);
        IF v_early.kind <> 'early_event' OR v_early.consumed_at IS NOT NULL
          OR v_early.mailbox_id <> v_row.waiter_mailbox_id
          OR v_early.event_type <> v_row.match_event_type
          OR v_early.correlation_digest IS NULL OR v_row.correlation_digest IS NULL
          OR NOT (v_early.correlation_digest = ANY (v_digests))
          OR NOT (v_row.correlation_digest = ANY (v_digests)) THEN
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

  defp plain do
    ~S"""
    CREATE FUNCTION relay_fn.correlation_plain_batch(p_limit integer)
      RETURNS TABLE (source text, id uuid, created_at timestamptz, event_type text,
        correlation_key text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      (SELECT 'waitpoint'::text, w.id, w.created_at, w.match_event_type::text, w.correlation_key
        FROM relay.waitpoints w
        WHERE w.tenant_id = relay_private.ctx_tenant_id()
          AND w.environment = relay_private.ctx_environment() AND w.correlation_key IS NOT NULL
        ORDER BY w.id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500))
      UNION ALL
      (SELECT 'mailbox_record'::text, r.id, r.created_at, r.event_type::text, r.correlation_key
        FROM relay.mailbox_records r
        WHERE r.tenant_id = relay_private.ctx_tenant_id()
          AND r.environment = relay_private.ctx_environment() AND r.correlation_key IS NOT NULL
        ORDER BY r.id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500))
    $fn$
    """
  end

  defp fill do
    ~S"""
    CREATE FUNCTION relay_fn.correlation_digest_fill(p_sources text[], p_ids uuid[],
      p_created_at timestamptz[], p_digests bytea[])
      RETURNS bigint
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_count bigint := 0;
      v_rows bigint;
      v_n integer := COALESCE(cardinality(p_ids), 0);
    BEGIN
      IF COALESCE(cardinality(p_sources), 0) <> v_n OR COALESCE(cardinality(p_created_at), 0) <> v_n
        OR COALESCE(cardinality(p_digests), 0) <> v_n
        OR EXISTS (SELECT 1 FROM unnest(p_digests) AS d(digest)
          WHERE d.digest IS NULL OR octet_length(d.digest) <> 32) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-65';
      END IF;
      FOR i IN 1..v_n LOOP
        IF p_sources[i] = 'waitpoint' THEN
          UPDATE relay.waitpoints w SET correlation_digest = p_digests[i], correlation_key = NULL,
              updated_at = now()
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_ids[i]
              AND w.correlation_key IS NOT NULL;
        ELSIF p_sources[i] = 'mailbox_record' THEN
          UPDATE relay.mailbox_records r SET correlation_digest = p_digests[i],
              correlation_key = NULL, updated_at = now()
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_ids[i]
              AND r.created_at = p_created_at[i] AND r.correlation_key IS NOT NULL;
        ELSE
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-65';
        END IF;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_count := v_count + v_rows;
      END LOOP;
      RETURN v_count;
    END
    $fn$
    """
  end
end
