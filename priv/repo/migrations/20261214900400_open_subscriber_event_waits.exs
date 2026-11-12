defmodule Relay.Repo.Migrations.OpenSubscriberEventWaits do
  use Ecto.Migration

  # WF-12
  # AG-13
  # AG-14
  # OP-57
  def up do
    execute(
      "ALTER TABLE relay.waitpoints VALIDATE CONSTRAINT waitpoints_waiter_kind_subscriber_check"
    )

    execute("ALTER TABLE relay.waitpoints DROP CONSTRAINT waitpoints_waiter_kind_check")
    execute("SET LOCAL ROLE relay_owner")
    execute(open())
    execute(offer())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp open do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.waitpoint_open(p_id uuid, p_kind text, p_waiter_kind text,
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
      IF p_condition IS NOT NULL AND (p_waiter_kind <> 'subscriber' OR p_kind <> 'event') THEN
        RETURN QUERY SELECT 'condition_unsupported'::text, NULL::uuid, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.waitpoint_lock(p_match_event_type, p_correlation_key);
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
          AND w.correlation_key = p_correlation_key AND w.state IN ('open', 'stalled')) THEN
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
        waiter_mailbox_id, match_event_type, correlation_key, condition, response_schema,
        subject_digest, content_ct, claim_text_ct, default_response_ct, field_key_id,
        escalation_policy_ref, surface_policy, deliver_to_topics, tags, opened_at, expires_at,
        heartbeat_interval_ms, heartbeat_due_at, state, state_changed_at, version, traceparent,
        created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_kind, p_waiter_kind, p_waiter_ref, v_mailbox,
        p_match_event_type, p_correlation_key, p_condition, p_response_schema, p_subject_digest,
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
        FOR NO KEY UPDATE;
      PERFORM relay_private.waitpoint_emit(v_row, 'waitpoint.created', NULL, NULL, NULL, NULL);
      RETURN QUERY SELECT 'opened'::text, v_row.id, v_row.expires_at, v_early;
    END
    $fn$
    """
  end

  defp offer do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.waitpoint_event_offer(p_event_id uuid, p_event_type text,
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
        CASE WHEN p_waiter_kind <> 'subscriber' THEN p_waiter_kind END,
        CASE WHEN p_waiter_kind <> 'subscriber' THEN p_waiter_ref END, NULL, 'waitpoint.no_match',
        p_payload_digest);
      RETURN QUERY SELECT 'unmatched'::text, NULL::uuid, NULL::uuid;
    END
    $fn$
    """
  end
end
