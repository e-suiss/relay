defmodule Relay.Repo.Migrations.CreateResponseCollectionFunctions do
  use Ecto.Migration

  @emit "relay_private.waitpoint_emit(relay.waitpoints, text, uuid, uuid, bytea, uuid, uuid, jsonb)"

  @functions [
    "relay_fn.waitpoint_response_token_mint(uuid, uuid, uuid, bigint)",
    "relay_fn.waitpoint_response_token_consume(uuid, text, bytea, uuid, bytea)",
    "relay_fn.waitpoint_response_token_process(uuid, uuid)"
  ]

  # AG-11
  # AG-16
  # AG-25
  # AG-26
  # AG-27
  # AG-28
  # AG-31
  # AG-32
  # AG-35
  # AG-62
  # E-86
  # INV-31
  # INV-33
  # INV-12
  def up do
    execute(emit())
    execute("REVOKE ALL ON FUNCTION #{@emit} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@emit} TO relay_owner")
    execute(emit_plain())

    execute("SET LOCAL ROLE relay_owner")
    execute(respond())
    execute("RESET ROLE")

    Enum.each([mint(), consume(), process()], &execute/1)

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp emit do
    ~S"""
    CREATE FUNCTION relay_private.waitpoint_emit(p_waitpoint relay.waitpoints,
      p_event_type text, p_record_id uuid, p_source_event_id uuid, p_payload_ct bytea,
      p_payload_key_id uuid, p_payload_subject_key_id uuid, p_data jsonb)
      RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    DECLARE
      v_seq bigint;
      v_data jsonb := jsonb_build_object('waitpoint_id', p_waitpoint.id, 'kind', p_waitpoint.kind);
      v_response relay.waitpoint_responses;
      v_reader uuid;
      v_mailbox uuid;
    BEGIN
      SELECT a.seq INTO v_seq
        FROM relay_fn.mailbox_append(COALESCE(p_record_id, uuidv7()), p_waitpoint.waiter_mailbox_id,
          'waitpoint_event', p_event_type, NULL, p_waitpoint.id, p_source_event_id,
          CASE WHEN p_payload_key_id IS NOT NULL OR p_payload_subject_key_id IS NOT NULL
            THEN p_payload_ct END,
          CASE WHEN p_payload_ct IS NOT NULL THEN p_payload_subject_key_id END,
          CASE WHEN p_payload_ct IS NOT NULL AND p_payload_subject_key_id IS NULL
            THEN p_payload_key_id END,
          sha256(convert_to(jsonb_build_object('waitpoint_id', p_waitpoint.id, 'event_type',
            p_event_type, 'state', p_waitpoint.state)::text, 'UTF8')),
          p_waitpoint.traceparent) a;
      IF p_event_type = 'waitpoint.cancelled' AND p_waitpoint.cancel_reason IS NOT NULL THEN
        v_data := v_data || jsonb_build_object('reason', p_waitpoint.cancel_reason);
      ELSIF p_event_type = 'waitpoint.resolved'
        AND p_waitpoint.resolution_response_id IS NOT NULL THEN
        SELECT * INTO v_response FROM relay.waitpoint_responses r
          WHERE r.tenant_id = p_waitpoint.tenant_id AND r.environment = p_waitpoint.environment
            AND r.id = p_waitpoint.resolution_response_id;
        IF FOUND THEN
          v_data := v_data || jsonb_build_object('response_id', v_response.id,
            'responder', jsonb_build_object('recipient_id', v_response.responder_recipient_id,
              'kind', (SELECT c.kind FROM relay.recipients c
                WHERE c.tenant_id = v_response.tenant_id AND c.environment = v_response.environment
                  AND c.id = v_response.responder_recipient_id)),
            'channel', CASE WHEN v_response.via IN ('push', 'web_push', 'email', 'sms', 'voice',
              'whatsapp', 'slack', 'teams', 'telegram', 'discord', 'in_app', 'webhook')
              THEN v_response.via END,
            'evidence_level', v_response.evidence_level,
            'responded_at', v_response.responded_at,
            'subject_digest', 'sha256:' || encode(v_response.subject_digest, 'hex'),
            'response_digest', 'sha256:' || encode(v_response.value_digest, 'hex'));
          IF v_response.evidence_level = 'access_aas_ref' THEN
            v_data := v_data
              || jsonb_build_object('access_decision_ref', v_response.evidence_ref);
          END IF;
        END IF;
      END IF;
      v_data := v_data || COALESCE(p_data, '{}'::jsonb);
      PERFORM relay_fn.outbox_append(uuidv7(), p_event_type,
        'waitpoint:' || p_waitpoint.id::text, v_data, p_waitpoint.traceparent);
      IF cardinality(p_waitpoint.deliver_to_topics) > 0
        AND p_event_type IN ('waitpoint.resolved', 'waitpoint.expired', 'waitpoint.cancelled') THEN
        FOR v_reader IN
          SELECT DISTINCT s.recipient_id
          FROM relay.topics t
          LEFT JOIN relay.topics p ON p.tenant_id = t.tenant_id AND p.environment = t.environment
            AND p.id = t.parent_id AND p.state = 'active'
          JOIN relay.topic_subscriptions s ON s.tenant_id = t.tenant_id
            AND s.environment = t.environment AND s.topic_id IN (t.id, p.id) AND s.state = 'active'
          JOIN relay.recipients r ON r.tenant_id = s.tenant_id AND r.environment = s.environment
            AND r.id = s.recipient_id AND r.kind = 'agent' AND r.state = 'active'
          WHERE t.tenant_id = p_waitpoint.tenant_id AND t.environment = p_waitpoint.environment
            AND t.key = ANY (p_waitpoint.deliver_to_topics) AND t.state = 'active'
            AND (p_waitpoint.waiter_kind <> 'agent' OR s.recipient_id <> p_waitpoint.waiter_ref)
          ORDER BY s.recipient_id
        LOOP
          v_mailbox := NULL;
          SELECT e.mailbox_id INTO v_mailbox
            FROM relay_fn.mailbox_ensure(uuidv7(), 'agent', v_reader) e
            WHERE e.result IN ('created', 'exists');
          IF v_mailbox IS NOT NULL THEN
            PERFORM relay_fn.mailbox_append(uuidv7(), v_mailbox, 'waitpoint_event', p_event_type,
              NULL, p_waitpoint.id, p_source_event_id, NULL, NULL, NULL,
              sha256(convert_to(jsonb_build_object('waitpoint_id', p_waitpoint.id, 'event_type',
                p_event_type, 'state', p_waitpoint.state)::text, 'UTF8')),
              p_waitpoint.traceparent);
          END IF;
        END LOOP;
      END IF;
      RETURN v_seq;
    END
    $fn$
    """
  end

  defp emit_plain do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.waitpoint_emit(p_waitpoint relay.waitpoints,
      p_event_type text, p_record_id uuid, p_source_event_id uuid, p_payload_ct bytea,
      p_payload_key_id uuid)
      RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
    BEGIN
      RETURN relay_private.waitpoint_emit(p_waitpoint, p_event_type, p_record_id,
        p_source_event_id, p_payload_ct, p_payload_key_id, NULL::uuid, NULL::jsonb);
    END
    $fn$
    """
  end

  defp respond do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.waitpoint_respond(p_waitpoint_id uuid, p_response_id uuid,
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
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      IF v_row.kind = 'event' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-72';
      END IF;
      IF v_row.state = 'resolved' AND p_source_record_id IS NULL AND EXISTS (
        SELECT 1 FROM relay.waitpoint_responses r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env
          AND r.id = v_row.resolution_response_id
          AND r.responder_recipient_id = p_responder_recipient_id
          AND r.value_digest = p_value_digest) THEN
        RETURN QUERY SELECT 'duplicate'::text, v_row.resolution_response_id;
        RETURN;
      END IF;
      IF p_source_record_id IS NOT NULL THEN
        SELECT * INTO v_early FROM relay.mailbox_records r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_source_record_id
            AND r.created_at BETWEEN uuid_extract_timestamp(p_source_record_id) - interval '5 minutes'
              AND uuid_extract_timestamp(p_source_record_id) + interval '5 minutes'
          FOR NO KEY UPDATE;
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
      ELSIF v_row.profile = 'guardian_approval' AND p_evidence_level <> 'access_aas_ref' THEN
        v_reason := 'evidence_level';
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
          NULL, NULL, jsonb_build_object('rule_id', 'waitpoint.response_' || v_reason));
        RETURN QUERY SELECT CASE v_reason
            WHEN 'closed' THEN 'rejected_closed'
            WHEN 'expired' THEN 'rejected_expired'
            WHEN 'is_waiter' THEN 'rejected_is_waiter'
            WHEN 'not_responder' THEN 'rejected_not_responder'
            WHEN 'evidence_level' THEN 'rejected_evidence_level'
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
      PERFORM relay_private.waitpoint_emit(v_row, 'waitpoint.resolved', NULL, NULL, p_value_ct,
        NULL, p_value_key_id, NULL);
      RETURN QUERY SELECT 'resolved'::text, p_response_id;
    END
    $fn$
    """
  end

  defp mint do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_response_token_mint(p_id uuid, p_waitpoint_id uuid,
      p_recipient_id uuid, p_ttl_ms bigint)
      RETURNS TABLE (result text, expires_at timestamptz)
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
      v_expires timestamptz;
    BEGIN
      IF p_recipient_id IS NULL OR p_ttl_ms IS NULL OR p_ttl_ms < 1000 OR p_ttl_ms > 86400000 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-31';
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      SELECT * INTO v_row FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
        FOR NO KEY UPDATE;
      IF NOT FOUND OR v_row.kind = 'event' THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.state NOT IN ('open', 'stalled') OR v_now >= v_row.expires_at THEN
        RETURN QUERY SELECT 'not_open'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_row.profile = 'guardian_approval' THEN
        RETURN QUERY SELECT 'profile_refused'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM relay.waitpoint_responders s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.waitpoint_id = p_waitpoint_id
          AND s.recipient_id = p_recipient_id) THEN
        RETURN QUERY SELECT 'not_responder'::text, NULL::timestamptz;
        RETURN;
      END IF;
      UPDATE relay.waitpoint_response_tokens t SET state = 'rotated', rotated_at = now(),
          updated_at = now()
        WHERE t.tenant_id = v_tenant AND t.environment = v_env
          AND t.waitpoint_id = p_waitpoint_id AND t.recipient_id = p_recipient_id
          AND t.state = 'issued';
      v_expires := LEAST(v_now + p_ttl_ms * interval '1 millisecond', v_row.expires_at);
      INSERT INTO relay.waitpoint_response_tokens (tenant_id, environment, id, waitpoint_id,
        recipient_id, state, expires_at, created_at, updated_at)
      VALUES (v_tenant, v_env, p_id, p_waitpoint_id, p_recipient_id, 'issued', v_expires, now(),
        now());
      RETURN QUERY SELECT 'minted'::text, v_expires;
    END
    $fn$
    """
  end

  defp consume do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_response_token_consume(p_id uuid, p_via text,
      p_value_ct bytea, p_value_key_id uuid, p_value_digest bytea)
      RETURNS TABLE (result text, waitpoint_id uuid, recipient_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := relay_private.business_now();
      v_token relay.waitpoint_response_tokens;
    BEGIN
      IF p_via IS NULL OR p_value_ct IS NULL OR p_value_key_id IS NULL
        OR p_value_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-31';
      END IF;
      SELECT * INTO v_token FROM relay.waitpoint_response_tokens t
        WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid;
        RETURN;
      END IF;
      IF v_token.state IN ('processing', 'settled') THEN
        RETURN QUERY SELECT CASE WHEN v_token.value_digest = p_value_digest THEN 'replayed'
            ELSE 'already_consumed' END,
          v_token.waitpoint_id, v_token.recipient_id;
        RETURN;
      END IF;
      IF v_token.state = 'rotated' THEN
        RETURN QUERY SELECT 'rotated'::text, v_token.waitpoint_id, v_token.recipient_id;
        RETURN;
      END IF;
      IF v_now >= v_token.expires_at THEN
        RETURN QUERY SELECT 'expired'::text, v_token.waitpoint_id, v_token.recipient_id;
        RETURN;
      END IF;
      UPDATE relay.waitpoint_response_tokens t SET state = 'processing', via = p_via,
          value_ct = p_value_ct, value_key_id = p_value_key_id, value_digest = p_value_digest,
          consumed_at = v_now, updated_at = now()
        WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_id;
      RETURN QUERY SELECT 'consumed'::text, v_token.waitpoint_id, v_token.recipient_id;
    END
    $fn$
    """
  end

  defp process do
    ~S"""
    CREATE FUNCTION relay_fn.waitpoint_response_token_process(p_id uuid, p_response_id uuid)
      RETURNS TABLE (result text, outcome text)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_token relay.waitpoint_response_tokens;
      v_subject bytea;
      v_outcome text;
    BEGIN
      SELECT * INTO v_token FROM relay.waitpoint_response_tokens t
        WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::text;
        RETURN;
      END IF;
      IF v_token.state = 'settled' THEN
        RETURN QUERY SELECT 'already_settled'::text, v_token.outcome;
        RETURN;
      END IF;
      IF v_token.state <> 'processing' THEN
        RETURN QUERY SELECT 'not_processing'::text, NULL::text;
        RETURN;
      END IF;
      SELECT w.subject_digest INTO v_subject FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_token.waitpoint_id;
      SELECT a.result INTO v_outcome
        FROM relay_fn.waitpoint_respond(v_token.waitpoint_id, p_response_id, v_token.recipient_id,
          'response_token:' || v_token.id::text, 'response_token:' || v_token.id::text,
          v_token.via, 'channel_claim', NULL, v_subject, v_token.value_ct, v_token.value_key_id,
          v_token.value_digest, NULL) a;
      UPDATE relay.waitpoint_response_tokens t SET state = 'settled', outcome = v_outcome,
          settled_at = now(), value_ct = NULL, updated_at = now()
        WHERE t.tenant_id = v_tenant AND t.environment = v_env AND t.id = p_id;
      RETURN QUERY SELECT 'settled'::text, v_outcome;
    END
    $fn$
    """
  end
end
