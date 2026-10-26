defmodule Relay.Repo.Migrations.CreateMailboxFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.mailbox_ensure(uuid, text, uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.mailbox_append(uuid, uuid, text, text, text, uuid, uuid, bytea, uuid, uuid, bytea, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.mailbox_cursor_check(uuid, bigint, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_fn.mailbox_read_since(uuid, bigint, bigint, integer)", "relay_owner",
     ~w(relay_app relay_report)},
    {"relay_fn.mailbox_lease(uuid, text, integer, bigint, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_fn.mailbox_ack(uuid, uuid[], text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.mailbox_cursor_advance(uuid, text, bigint, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_fn.mailbox_epoch_bump(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.mailbox_set_state(uuid, text, text)", "relay_owner", ~w(relay_app)}
  ]

  # C-68
  # C-71
  # IN-1
  # IN-22
  # AG-20
  # AG-21
  # AG-22
  # AG-24
  # AG-64
  # OP-5
  # INV-35
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
    [
      ~S"""
      CREATE FUNCTION relay_fn.mailbox_ensure(p_id uuid, p_owner_kind text, p_owner_ref uuid)
        RETURNS TABLE (result text, mailbox_id uuid, stream_key text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_id uuid;
        v_stream text;
      BEGIN
        IF p_owner_kind IS NULL OR p_owner_kind NOT IN ('subscriber', 'agent', 'api_client')
          OR p_owner_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-1';
        END IF;
        SELECT m.id, m.stream_key INTO v_id, v_stream FROM relay.mailboxes m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.owner_kind = p_owner_kind
            AND m.owner_ref = p_owner_ref;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_id, v_stream;
          RETURN;
        END IF;
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::text;
          RETURN;
        END IF;
        IF p_owner_kind IN ('subscriber', 'agent') AND NOT EXISTS (SELECT 1 FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_owner_ref
            AND r.kind = p_owner_kind AND r.state = 'active') THEN
          RETURN QUERY SELECT 'owner_not_found'::text, NULL::uuid, NULL::text;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.mailboxes AS m (tenant_id, environment, id, owner_kind, owner_ref,
          stream_key, state, replay_floor_seq, open_waitpoints, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_owner_kind, p_owner_ref, 'mailbox:' || p_id::text, 'active',
          0, 0, now(), now())
        ON CONFLICT (tenant_id, environment, owner_kind, owner_ref) DO NOTHING
        RETURNING m.id, m.stream_key INTO v_id, v_stream;
        IF v_id IS NOT NULL THEN
          RETURN QUERY SELECT 'created'::text, v_id, v_stream;
          RETURN;
        END IF;
        SELECT m.id, m.stream_key INTO v_id, v_stream FROM relay.mailboxes m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.owner_kind = p_owner_kind
            AND m.owner_ref = p_owner_ref;
        RETURN QUERY SELECT 'exists'::text, v_id, v_stream;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.mailbox_append(p_id uuid, p_mailbox_id uuid, p_kind text,
        p_event_type text, p_correlation_key text, p_waitpoint_id uuid, p_source_event_id uuid,
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
          seq, kind, event_type, correlation_key, waitpoint_id, source_event_id, payload_ct,
          payload_subject_key_id, payload_tenant_key_id, payload_digest, delivery_state,
          delivery_count, traceparent, updated_at)
        VALUES (v_tenant, v_env, p_id, now(), p_mailbox_id, v_epoch, v_seq, p_kind, p_event_type,
          p_correlation_key, p_waitpoint_id, p_source_event_id, p_payload_ct,
          p_payload_subject_key_id, p_payload_tenant_key_id, p_payload_digest,
          CASE WHEN p_kind = 'early_event' THEN 'held' ELSE 'available' END, 0, p_traceparent,
          now());
        RETURN QUERY SELECT 'appended'::text, v_epoch, v_seq;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.mailbox_cursor_check(p_mailbox_id uuid, p_epoch bigint,
        p_since_seq bigint)
        RETURNS TABLE (result text, current_epoch bigint, head_seq bigint, replay_floor_seq bigint)
      LANGUAGE plpgsql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_stream text;
        v_floor bigint;
        v_epoch bigint;
        v_head bigint;
      BEGIN
        SELECT m.stream_key, m.replay_floor_seq INTO v_stream, v_floor FROM relay.mailboxes m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mailbox_id;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint, NULL::bigint, NULL::bigint;
          RETURN;
        END IF;
        SELECT h.epoch, h.last_seq INTO v_epoch, v_head FROM relay.stream_heads h
          WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.stream_key = v_stream;
        v_epoch := COALESCE(v_epoch, 1);
        v_head := COALESCE(v_head, 0);
        IF p_epoch IS DISTINCT FROM v_epoch OR p_since_seq IS NULL OR p_since_seq < v_floor
          OR p_since_seq > v_head THEN
          RETURN QUERY SELECT 'resync_required'::text, v_epoch, v_head, v_floor;
          RETURN;
        END IF;
        RETURN QUERY SELECT 'ok'::text, v_epoch, v_head, v_floor;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.mailbox_read_since(p_mailbox_id uuid, p_epoch bigint,
        p_since_seq bigint, p_limit integer)
        RETURNS TABLE (id uuid, epoch bigint, seq bigint, kind text, event_type text,
          waitpoint_id uuid, payload_ct bytea, payload_subject_key_id uuid,
          payload_tenant_key_id uuid, payload_digest bytea, delivery_state text,
          created_at timestamptz)
      LANGUAGE plpgsql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      BEGIN
        IF p_mailbox_id IS NULL OR p_epoch IS NULL OR p_since_seq IS NULL OR p_limit IS NULL
          OR p_limit < 1 OR p_limit > 501 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-29';
        END IF;
        RETURN QUERY
          SELECT r.id, r.epoch, r.seq, r.kind, r.event_type::text, r.waitpoint_id, r.payload_ct,
            r.payload_subject_key_id, r.payload_tenant_key_id, r.payload_digest::bytea,
            r.delivery_state, r.created_at
          FROM relay.mailbox_records r
          WHERE r.tenant_id = relay_private.ctx_tenant_id()
            AND r.environment = relay_private.ctx_environment()
            AND r.mailbox_id = p_mailbox_id AND r.epoch = p_epoch AND r.seq > p_since_seq
          ORDER BY r.seq
          LIMIT p_limit;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.mailbox_lease(p_mailbox_id uuid, p_holder text, p_max integer,
        p_lease_ms bigint, p_max_deliveries bigint)
        RETURNS TABLE (id uuid, epoch bigint, seq bigint, event_type text, waitpoint_id uuid,
          payload_ct bytea, payload_subject_key_id uuid, payload_tenant_key_id uuid,
          payload_digest bytea, delivery_count bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_mailbox relay.mailboxes;
        v_row relay.mailbox_records;
      BEGIN
        IF p_holder IS NULL OR char_length(p_holder) NOT BETWEEN 1 AND 128
          OR p_max IS NULL OR p_max NOT BETWEEN 1 AND 100
          OR p_lease_ms IS NULL OR p_lease_ms NOT BETWEEN 1000 AND 3600000
          OR p_max_deliveries IS NULL OR p_max_deliveries NOT BETWEEN 1 AND 1000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-22';
        END IF;
        SELECT * INTO v_mailbox FROM relay.mailboxes m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mailbox_id;
        IF NOT FOUND OR v_mailbox.state <> 'active' THEN
          RETURN;
        END IF;
        FOR v_row IN
          SELECT * FROM relay.mailbox_records r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.mailbox_id = p_mailbox_id
            AND (r.delivery_state = 'available'
              OR (r.delivery_state = 'leased' AND r.lease_until < now()))
          ORDER BY r.epoch, r.seq
          LIMIT p_max
          FOR NO KEY UPDATE SKIP LOCKED
        LOOP
          IF v_row.delivery_count + 1 > p_max_deliveries THEN
            UPDATE relay.mailbox_records r SET delivery_state = 'dead_lettered',
                dead_lettered_at = now(), lease_holder = NULL, lease_until = NULL, updated_at = now()
              WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_row.id
                AND r.created_at = v_row.created_at;
            PERFORM relay_fn.outbox_append(uuidv7(), 'mailbox.record_dead_lettered',
              v_mailbox.stream_key, jsonb_build_object('mailbox_id', p_mailbox_id, 'record_id',
                v_row.id, 'epoch', v_row.epoch, 'seq', v_row.seq, 'delivery_count',
                v_row.delivery_count), v_row.traceparent);
          ELSE
            UPDATE relay.mailbox_records r SET delivery_state = 'leased', lease_holder = p_holder,
                lease_until = now() + p_lease_ms * interval '1 millisecond',
                delivery_count = r.delivery_count + 1, updated_at = now()
              WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_row.id
                AND r.created_at = v_row.created_at;
            id := v_row.id;
            epoch := v_row.epoch;
            seq := v_row.seq;
            event_type := v_row.event_type;
            waitpoint_id := v_row.waitpoint_id;
            payload_ct := v_row.payload_ct;
            payload_subject_key_id := v_row.payload_subject_key_id;
            payload_tenant_key_id := v_row.payload_tenant_key_id;
            payload_digest := v_row.payload_digest;
            delivery_count := v_row.delivery_count + 1;
            RETURN NEXT;
          END IF;
        END LOOP;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.mailbox_ack(p_mailbox_id uuid, p_record_ids uuid[], p_holder text)
        RETURNS TABLE (record_id uuid, result text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_id uuid;
        v_row relay.mailbox_records;
      BEGIN
        IF p_holder IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-21';
        END IF;
        FOR v_id IN
          SELECT DISTINCT x.rid FROM unnest(COALESCE(p_record_ids, ARRAY[]::uuid[])) AS x(rid)
          WHERE x.rid IS NOT NULL ORDER BY x.rid
        LOOP
          SELECT * INTO v_row FROM relay.mailbox_records r
            WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_id
              AND r.mailbox_id = p_mailbox_id
              AND r.created_at BETWEEN uuid_extract_timestamp(v_id) - interval '5 minutes'
                AND uuid_extract_timestamp(v_id) + interval '5 minutes'
            FOR NO KEY UPDATE;
          record_id := v_id;
          IF NOT FOUND THEN
            result := 'not_found';
          ELSIF v_row.delivery_state = 'acked' THEN
            result := 'already_acked';
          ELSIF v_row.delivery_state = 'leased' AND v_row.lease_holder = p_holder THEN
            UPDATE relay.mailbox_records r SET delivery_state = 'acked', acked_at = now(),
                lease_holder = NULL, lease_until = NULL, updated_at = now()
              WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_id
                AND r.created_at = v_row.created_at;
            result := 'acked';
          ELSE
            result := 'lease_lost';
          END IF;
          RETURN NEXT;
        END LOOP;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.mailbox_cursor_advance(p_mailbox_id uuid, p_consumer text,
        p_epoch bigint, p_seq bigint)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_stream text;
        v_epoch bigint;
        v_cursor relay.mailbox_cursors;
      BEGIN
        IF p_consumer IS NULL OR p_epoch IS NULL OR p_seq IS NULL OR p_seq < 0 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-22';
        END IF;
        SELECT m.stream_key INTO v_stream FROM relay.mailboxes m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mailbox_id;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        SELECT h.epoch INTO v_epoch FROM relay.stream_heads h
          WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.stream_key = v_stream;
        IF p_epoch <> COALESCE(v_epoch, 1) THEN
          RETURN 'epoch_mismatch';
        END IF;
        SELECT * INTO v_cursor FROM relay.mailbox_cursors c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.mailbox_id = p_mailbox_id
            AND c.consumer = p_consumer
          FOR NO KEY UPDATE;
        IF FOUND AND v_cursor.epoch = p_epoch AND v_cursor.seq >= p_seq THEN
          RETURN 'stale';
        END IF;
        INSERT INTO relay.mailbox_cursors AS c (tenant_id, environment, mailbox_id, consumer, epoch,
          seq, updated_at)
        VALUES (v_tenant, v_env, p_mailbox_id, p_consumer, p_epoch, p_seq, now())
        ON CONFLICT (tenant_id, environment, mailbox_id, consumer) DO UPDATE
          SET epoch = EXCLUDED.epoch, seq = EXCLUDED.seq, updated_at = now();
        RETURN 'advanced';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.mailbox_epoch_bump(p_mailbox_id uuid, p_reason text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, epoch bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_stream text;
        v_epoch bigint;
      BEGIN
        IF p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 1 AND 200 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-26';
        END IF;
        SELECT m.stream_key INTO v_stream FROM relay.mailboxes m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mailbox_id
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        INSERT INTO relay.stream_heads AS h (tenant_id, environment, stream_key, epoch, last_seq,
          updated_at)
        VALUES (v_tenant, v_env, v_stream, 2, 0, now())
        ON CONFLICT (tenant_id, environment, stream_key)
          DO UPDATE SET epoch = h.epoch + 1, last_seq = 0, updated_at = now()
        RETURNING h.epoch INTO v_epoch;
        PERFORM relay_fn.outbox_append(uuidv7(), 'stream.resync_required', v_stream,
          jsonb_build_object('mailbox_id', p_mailbox_id, 'epoch', v_epoch, 'reason', p_reason),
          NULL);
        PERFORM relay_private.audit_write(v_tenant, v_env, 'mailbox.epoch_bumped', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'mailbox', p_mailbox_id::text,
          p_reason, p_record_digest);
        RETURN QUERY SELECT 'bumped'::text, v_epoch;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.mailbox_set_state(p_mailbox_id uuid, p_state text, p_reason text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_state text;
      BEGIN
        IF p_state IS NULL OR p_state NOT IN ('active', 'suspended', 'deleted')
          OR (p_state = 'deleted' AND (p_reason IS NULL
            OR p_reason NOT IN ('erasure', 'retention_end', 'tenant_closed', 'operator'))) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-5';
        END IF;
        SELECT m.state INTO v_state FROM relay.mailboxes m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mailbox_id
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state = p_state OR v_state = 'deleted' THEN
          RETURN 'unchanged';
        END IF;
        UPDATE relay.mailboxes m SET state = p_state,
            deleted_at = CASE WHEN p_state = 'deleted' THEN now() END,
            deleted_reason = CASE WHEN p_state = 'deleted' THEN p_reason END, updated_at = now()
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mailbox_id;
        RETURN 'changed';
      END
      $fn$
      """
    ]
  end
end
