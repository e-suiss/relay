defmodule Relay.Repo.Migrations.CreateFirstContactFunctions do
  use Ecto.Migration

  @functions [
    "relay_fn.agent_relationship_apply(uuid, uuid, text, bigint, text)",
    "relay_fn.agent_block_set(uuid, uuid, boolean, text)",
    "relay_fn.agent_message_send(uuid, uuid, uuid, text, integer, bytea, uuid, bytea, text, bytea, bytea, bigint, bigint, text)",
    "relay_fn.mailbox_abuse_report(uuid, uuid, uuid, text, text)"
  ]

  # AG-56
  # AG-57
  # AG-59
  # AG-60
  # AG-61
  # AG-69
  # AG-70
  # AG-73
  # C-68
  # OP-5
  def up do
    Enum.each(statements(), &execute/1)

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.agent_relationship_apply(p_owner_agent_id uuid,
        p_peer_agent_id uuid, p_level text, p_sequence bigint, p_source_event_ref text)
        RETURNS TABLE (result text, level text, sequence bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.agent_relationships;
        v_agents bigint;
      BEGIN
        IF p_owner_agent_id IS NULL OR p_peer_agent_id IS NULL
          OR p_owner_agent_id = p_peer_agent_id
          OR p_level IS NULL OR p_level NOT IN ('unknown', 'known', 'verified', 'trusted')
          OR p_sequence IS NULL OR p_sequence < 0
          OR p_source_event_ref IS NULL
          OR char_length(p_source_event_ref) NOT BETWEEN 1 AND 256 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-73';
        END IF;
        SELECT count(*) INTO v_agents FROM relay.agents a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env
            AND a.id IN (p_owner_agent_id, p_peer_agent_id);
        IF v_agents <> 2 THEN
          RETURN QUERY SELECT 'agent_not_found'::text, NULL::text, NULL::bigint;
          RETURN;
        END IF;
        INSERT INTO relay.agent_relationships AS r (tenant_id, environment, owner_agent_id,
          peer_agent_id, level, sequence, source_event_ref, created_at, updated_at)
        VALUES (v_tenant, v_env, p_owner_agent_id, p_peer_agent_id, p_level, p_sequence,
          p_source_event_ref, now(), now())
        ON CONFLICT (tenant_id, environment, owner_agent_id, peer_agent_id) DO NOTHING;
        IF FOUND THEN
          RETURN QUERY SELECT 'applied'::text, p_level, p_sequence;
          RETURN;
        END IF;
        SELECT * INTO v_row FROM relay.agent_relationships r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env
            AND r.owner_agent_id = p_owner_agent_id AND r.peer_agent_id = p_peer_agent_id
          FOR NO KEY UPDATE;
        IF v_row.sequence >= p_sequence THEN
          RETURN QUERY SELECT 'stale'::text, v_row.level, v_row.sequence;
          RETURN;
        END IF;
        UPDATE relay.agent_relationships r SET level = p_level, sequence = p_sequence,
            source_event_ref = p_source_event_ref, updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env
            AND r.owner_agent_id = p_owner_agent_id AND r.peer_agent_id = p_peer_agent_id;
        RETURN QUERY SELECT 'applied'::text, p_level, p_sequence;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.agent_block_set(p_owner_agent_id uuid, p_sender_agent_id uuid,
        p_blocked boolean, p_actor_ref text)
        RETURNS TABLE (result text, state text, blocked_at timestamptz, lifted_at timestamptz)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.agent_blocks;
        v_state text;
      BEGIN
        IF p_owner_agent_id IS NULL OR p_sender_agent_id IS NULL OR p_blocked IS NULL
          OR p_actor_ref IS NULL OR char_length(p_actor_ref) NOT BETWEEN 1 AND 256 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-61';
        END IF;
        IF p_owner_agent_id = p_sender_agent_id OR NOT EXISTS (SELECT 1 FROM relay.agents a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_sender_agent_id)
          OR NOT EXISTS (SELECT 1 FROM relay.agents a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_owner_agent_id
            AND a.state <> 'deleted') THEN
          RETURN QUERY SELECT 'sender_not_found'::text, NULL::text, NULL::timestamptz,
            NULL::timestamptz;
          RETURN;
        END IF;
        SELECT * INTO v_row FROM relay.agent_blocks b
          WHERE b.tenant_id = v_tenant AND b.environment = v_env
            AND b.owner_agent_id = p_owner_agent_id AND b.sender_agent_id = p_sender_agent_id
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          IF NOT p_blocked THEN
            RETURN QUERY SELECT 'unchanged'::text, 'lifted'::text, NULL::timestamptz,
              NULL::timestamptz;
            RETURN;
          END IF;
          INSERT INTO relay.agent_blocks (tenant_id, environment, owner_agent_id,
            sender_agent_id, state, blocked_at, lifted_at, changed_by_ref, created_at, updated_at)
          VALUES (v_tenant, v_env, p_owner_agent_id, p_sender_agent_id, 'blocked', now(), NULL,
            p_actor_ref, now(), now());
          RETURN QUERY SELECT 'blocked'::text, 'blocked'::text, now(), NULL::timestamptz;
          RETURN;
        END IF;
        v_state := CASE WHEN p_blocked THEN 'blocked' ELSE 'lifted' END;
        IF v_row.state = v_state THEN
          RETURN QUERY SELECT 'unchanged'::text, v_row.state, v_row.blocked_at, v_row.lifted_at;
          RETURN;
        END IF;
        UPDATE relay.agent_blocks b SET state = v_state,
            blocked_at = CASE WHEN p_blocked THEN now() ELSE b.blocked_at END,
            lifted_at = CASE WHEN p_blocked THEN NULL ELSE now() END,
            changed_by_ref = p_actor_ref, updated_at = now()
          WHERE b.tenant_id = v_tenant AND b.environment = v_env
            AND b.owner_agent_id = p_owner_agent_id AND b.sender_agent_id = p_sender_agent_id
          RETURNING * INTO v_row;
        RETURN QUERY SELECT v_state, v_row.state, v_row.blocked_at, v_row.lifted_at;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.agent_message_send(p_id uuid, p_recipient_agent_id uuid,
        p_sender_agent_id uuid, p_content_encryption text, p_size integer, p_payload_ct bytea,
        p_payload_tenant_key_id uuid, p_payload_digest bytea, p_token text, p_token_digest bytea,
        p_token_key_id bytea, p_hour_limit bigint, p_day_recipient_limit bigint,
        p_traceparent text)
        RETURNS TABLE (result text, box text, relationship text, epoch bigint, seq bigint,
          retry_after_seconds bigint, limit_name text, actual bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_now timestamptz := now();
        v_state text;
        v_mailbox uuid;
        v_mailbox_state text;
        v_stream text;
        v_level text;
        v_blocked boolean;
        v_first boolean := false;
        v_count bigint;
        v_oldest timestamptz;
        v_known boolean;
        v_box text;
        v_kind text;
        v_result text;
        v_epoch bigint;
        v_seq bigint;
      BEGIN
        IF p_recipient_agent_id IS NULL OR p_sender_agent_id IS NULL
          OR p_content_encryption IS NULL OR p_size IS NULL OR p_payload_ct IS NULL
          OR p_payload_tenant_key_id IS NULL OR p_payload_digest IS NULL
          OR p_token IS NULL OR p_token NOT IN ('none', 'valid', 'invalid')
          OR (p_token = 'valid' AND (p_token_digest IS NULL OR p_token_key_id IS NULL))
          OR p_hour_limit IS NULL OR p_hour_limit < 1
          OR p_day_recipient_limit IS NULL OR p_day_recipient_limit < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-60';
        END IF;
        IF p_recipient_agent_id = p_sender_agent_id THEN
          RETURN QUERY SELECT 'self'::text, NULL::text, NULL::text, NULL::bigint, NULL::bigint,
            NULL::bigint, NULL::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT a.state INTO v_state FROM relay.agents a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_sender_agent_id;
        IF NOT FOUND OR v_state <> 'active' THEN
          RETURN QUERY SELECT 'sender_not_found'::text, NULL::text, NULL::text, NULL::bigint,
            NULL::bigint, NULL::bigint, NULL::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT a.state INTO v_state FROM relay.agents a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_recipient_agent_id;
        IF NOT FOUND OR v_state = 'deleted' THEN
          RETURN QUERY SELECT 'recipient_not_found'::text, NULL::text, NULL::text, NULL::bigint,
            NULL::bigint, NULL::bigint, NULL::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT m.id, m.state, m.stream_key INTO v_mailbox, v_mailbox_state, v_stream
          FROM relay.mailboxes m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.owner_kind = 'agent'
            AND m.owner_ref = p_recipient_agent_id;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'recipient_not_found'::text, NULL::text, NULL::text, NULL::bigint,
            NULL::bigint, NULL::bigint, NULL::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_state <> 'active' OR v_mailbox_state <> 'active' THEN
          RETURN QUERY SELECT 'recipient_inactive'::text, NULL::text, NULL::text, NULL::bigint,
            NULL::bigint, NULL::bigint, NULL::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT r.level INTO v_level FROM relay.agent_relationships r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env
            AND r.owner_agent_id = p_recipient_agent_id AND r.peer_agent_id = p_sender_agent_id;
        v_level := COALESCE(v_level, 'unknown');
        v_blocked := EXISTS (SELECT 1 FROM relay.agent_blocks b
          WHERE b.tenant_id = v_tenant AND b.environment = v_env
            AND b.owner_agent_id = p_recipient_agent_id AND b.sender_agent_id = p_sender_agent_id
            AND b.state = 'blocked');
        IF v_level = 'unknown' THEN
          IF p_token <> 'valid' THEN
            RETURN QUERY SELECT CASE WHEN p_token = 'none' THEN 'token_required'
              ELSE 'token_invalid' END, NULL::text, NULL::text, NULL::bigint, NULL::bigint,
              NULL::bigint, NULL::text, NULL::bigint;
            RETURN;
          END IF;
          PERFORM pg_advisory_xact_lock(hashtextextended('relay.first_contact:'
            || v_tenant::text || ':' || v_env::text || ':' || p_sender_agent_id::text, 0));
          SELECT count(*), min(m.created_at) INTO v_count, v_oldest FROM relay.agent_messages m
            WHERE m.tenant_id = v_tenant AND m.environment = v_env
              AND m.sender_agent_id = p_sender_agent_id AND m.first_contact
              AND m.created_at > v_now - interval '1 hour';
          IF v_count >= p_hour_limit THEN
            RETURN QUERY SELECT 'rate_limited'::text, NULL::text, NULL::text, NULL::bigint,
              NULL::bigint,
              GREATEST(ceil(extract(epoch FROM v_oldest + interval '1 hour' - v_now)), 1)::bigint,
              'first_contact.messages_per_hour'::text, v_count;
            RETURN;
          END IF;
          SELECT count(DISTINCT m.recipient_agent_id), min(m.created_at),
              COALESCE(bool_or(m.recipient_agent_id = p_recipient_agent_id), false)
            INTO v_count, v_oldest, v_known FROM relay.agent_messages m
            WHERE m.tenant_id = v_tenant AND m.environment = v_env
              AND m.sender_agent_id = p_sender_agent_id AND m.first_contact
              AND m.created_at > v_now - interval '1 day';
          IF v_count >= p_day_recipient_limit AND NOT v_known THEN
            RETURN QUERY SELECT 'rate_limited'::text, NULL::text, NULL::text, NULL::bigint,
              NULL::bigint,
              GREATEST(ceil(extract(epoch FROM v_oldest + interval '1 day' - v_now)), 1)::bigint,
              'first_contact.recipients_per_day'::text, v_count;
            RETURN;
          END IF;
          INSERT INTO relay.first_contact_tokens (tenant_id, environment, token_digest,
            token_key_id, spent_at)
          VALUES (v_tenant, v_env, p_token_digest, p_token_key_id, v_now)
          ON CONFLICT (tenant_id, environment, token_digest) DO NOTHING;
          IF NOT FOUND THEN
            RETURN QUERY SELECT 'token_replayed'::text, NULL::text, NULL::text, NULL::bigint,
              NULL::bigint, NULL::bigint, NULL::text, NULL::bigint;
            RETURN;
          END IF;
          v_first := true;
        END IF;
        v_box := CASE WHEN v_blocked THEN 'blocked' WHEN v_first THEN 'requests'
          ELSE 'inbox' END;
        IF v_box = 'inbox' THEN
          SELECT a.result, a.epoch, a.seq INTO v_result, v_epoch, v_seq
            FROM relay_fn.mailbox_append(p_id, v_mailbox, 'message', 'agent.message', NULL, NULL,
              NULL, p_payload_ct, NULL, p_payload_tenant_key_id, p_payload_digest,
              p_traceparent) a;
          IF v_result <> 'appended' THEN
            RETURN QUERY SELECT 'recipient_inactive'::text, NULL::text, NULL::text, NULL::bigint,
              NULL::bigint, NULL::bigint, NULL::text, NULL::bigint;
            RETURN;
          END IF;
        ELSE
          PERFORM relay_private.assert_new_id(p_id);
          v_kind := CASE WHEN v_box = 'blocked' THEN 'blocked_message'
            ELSE 'request_message' END;
          IF v_box = 'requests' THEN
            SELECT o.epoch, o.seq INTO v_epoch, v_seq
              FROM relay_fn.outbox_append(uuidv7(), 'mailbox.request_received', v_stream,
                jsonb_build_object('mailbox_id', v_mailbox, 'record_id', p_id, 'kind', v_kind),
                p_traceparent) o;
          ELSE
            SELECT n.epoch, n.seq INTO v_epoch, v_seq FROM relay_fn.stream_next_seq(v_stream) n;
          END IF;
          INSERT INTO relay.mailbox_records (tenant_id, environment, id, created_at, mailbox_id,
            epoch, seq, kind, event_type, payload_ct, payload_tenant_key_id, payload_digest,
            delivery_state, delivery_count, traceparent, updated_at)
          VALUES (v_tenant, v_env, p_id, v_now, v_mailbox, v_epoch, v_seq, v_kind,
            'agent.message', p_payload_ct, p_payload_tenant_key_id, p_payload_digest, 'held', 0,
            p_traceparent, v_now);
        END IF;
        INSERT INTO relay.agent_messages (tenant_id, environment, record_id, record_created_at,
          mailbox_id, recipient_agent_id, sender_agent_id, box, trust_label, relationship,
          content_encryption, size, first_contact, created_at)
        SELECT v_tenant, v_env, p_id, r.created_at, v_mailbox, p_recipient_agent_id,
          p_sender_agent_id, v_box, CASE WHEN v_blocked THEN 'blocked' ELSE 'authenticated' END,
          v_level, p_content_encryption, p_size, v_first, v_now
          FROM relay.mailbox_records r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_id
            AND r.created_at BETWEEN uuid_extract_timestamp(p_id) - interval '5 minutes'
              AND uuid_extract_timestamp(p_id) + interval '5 minutes';
        RETURN QUERY SELECT 'sent'::text, v_box, v_level, v_epoch, v_seq, NULL::bigint,
          NULL::text, NULL::bigint;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.mailbox_abuse_report(p_id uuid, p_reporter_agent_id uuid,
        p_record_id uuid, p_sender_ref text, p_statement text)
        RETURNS TABLE (result text, report_id uuid, reported_at timestamptz,
          statement_attached boolean)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_now timestamptz := now();
        v_message relay.agent_messages;
        v_report relay.mailbox_abuse_reports;
        v_hour bigint;
        v_recipients bigint;
        v_data jsonb;
      BEGIN
        IF p_reporter_agent_id IS NULL OR p_record_id IS NULL OR p_sender_ref IS NULL
          OR char_length(p_sender_ref) NOT BETWEEN 1 AND 256
          OR char_length(p_statement) NOT BETWEEN 1 AND 8192 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-61';
        END IF;
        SELECT * INTO v_message FROM relay.agent_messages m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.record_id = p_record_id
            AND m.recipient_agent_id = p_reporter_agent_id;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::timestamptz, NULL::boolean;
          RETURN;
        END IF;
        SELECT * INTO v_report FROM relay.mailbox_abuse_reports a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.record_id = p_record_id;
        IF FOUND THEN
          RETURN QUERY SELECT 'already_reported'::text, v_report.id, v_report.created_at,
            v_report.statement_attached;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.mailbox_abuse_reports (tenant_id, environment, id, record_id,
          mailbox_id, reporter_agent_id, sender_agent_id, statement_attached, created_at)
        VALUES (v_tenant, v_env, p_id, p_record_id, v_message.mailbox_id, p_reporter_agent_id,
          v_message.sender_agent_id, p_statement IS NOT NULL, v_now);
        SELECT count(*) FILTER (WHERE m.created_at > v_message.created_at - interval '1 hour'),
            count(DISTINCT m.recipient_agent_id) INTO v_hour, v_recipients
          FROM relay.agent_messages m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env
            AND m.sender_agent_id = v_message.sender_agent_id
            AND m.created_at > v_message.created_at - interval '1 day'
            AND m.created_at <= v_message.created_at;
        v_data := jsonb_build_object('mailbox_id', v_message.mailbox_id, 'record_id', p_record_id,
          'sender_ref', p_sender_ref, 'reported_at', to_char(v_now,
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'sent_at', to_char(v_message.created_at,
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'size', v_message.size,
          'rate', jsonb_build_object('messages_last_hour', v_hour, 'recipients_last_day',
            v_recipients));
        IF p_statement IS NOT NULL THEN
          v_data := v_data || jsonb_build_object('statement', jsonb_build_object('marking',
            'reporter_statement_unverified', 'content', p_statement));
        END IF;
        PERFORM relay_fn.outbox_append(uuidv7(), 'mailbox.abuse_reported',
          'mailbox_abuse:' || v_message.mailbox_id::text, v_data, NULL);
        RETURN QUERY SELECT 'reported'::text, p_id, v_now, p_statement IS NOT NULL;
      END
      $fn$
      """
    ]
  end
end
