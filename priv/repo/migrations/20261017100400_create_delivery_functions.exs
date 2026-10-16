defmodule Relay.Repo.Migrations.CreateDeliveryFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @projection "relay_private.delivery_projection"

  @functions [
    {"relay_private.projection_zero()", "relay_migrator", ~w(relay_owner relay_app relay_report)},
    {"relay_private.projection_of(relay.deliveries)", "relay_migrator",
     ~w(relay_owner relay_app relay_report)},
    {"relay_private.projection_apply(#{@projection}, text, bigint, bigint, timestamp with time zone, timestamp with time zone, smallint, text, text, text, text, text, boolean)",
     "relay_migrator", ~w(relay_owner relay_app relay_report)},
    {"relay_private.ledger_record(uuid, relay.deliveries, bigint, text, text, text, text, bigint, timestamp with time zone, uuid, smallint, text, text, text, text, text, jsonb, text)",
     "relay_migrator", ~w(relay_owner)},
    {"relay_fn.notification_accept(uuid, uuid, uuid, text, text, text, text, text, text, timestamp with time zone, boolean, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.delivery_open(uuid, uuid, text, text, uuid, bytea, text, uuid, uuid, text, text, text, timestamp with time zone, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.delivery_cancel(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.notification_cancel(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.attempt_open(uuid, uuid, text, uuid, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.attempt_start(uuid, bigint)", "relay_owner", ~w(relay_app)},
    {"relay_fn.attempt_finish(uuid, bigint, text, text, text, text, uuid, timestamp with time zone, smallint, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.ledger_append(uuid, uuid, bigint, text, text, text, text, bigint, timestamp with time zone, uuid, smallint, text, text, text, text, jsonb, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.delivery_projection_rebuild(uuid)", "relay_owner", ~w(relay_app relay_report)},
    {"relay_fn.subject_erase(uuid, text, text[], text[], bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.webhook_receipt_record(uuid, text, uuid, text, bytea, bytea, uuid)", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.webhook_receipt_mark(uuid, text, text)", "relay_owner", ~w(relay_app)}
  ]

  # OP-3
  # OP-4
  # OP-7
  # OP-8
  # DS-1
  # DS-2
  # DS-4
  # DS-5
  # DS-6
  def up do
    execute(projection_type())
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")

    execute("DROP TYPE #{@projection}")
  end

  defp projection_type do
    ~S"""
    CREATE TYPE relay_private.delivery_projection AS (
      delivery_rank smallint,
      accepted_at timestamptz,
      delivered_at timestamptz,
      failure_kind text,
      failure_class text,
      failure_rule_id text,
      failure_reason text,
      failure_attempt_no bigint,
      failure_provider_seq bigint,
      failure_occurred_at timestamptz,
      failure_received_at timestamptz,
      has_conflict boolean,
      duplicate_delivered boolean,
      late_event_count bigint,
      projection_version bigint,
      last_event_at timestamptz,
      result text
    )
    """
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_private.projection_zero() RETURNS relay_private.delivery_projection
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT ROW(0::smallint, NULL::timestamptz, NULL::timestamptz, NULL::text, NULL::text,
          NULL::text, NULL::text, NULL::bigint, NULL::bigint, NULL::timestamptz, NULL::timestamptz,
          false, false, 0::bigint, 0::bigint, NULL::timestamptz, NULL::text
        )::relay_private.delivery_projection
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.projection_of(p_delivery relay.deliveries)
        RETURNS relay_private.delivery_projection
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT ROW(p_delivery.delivery_rank, p_delivery.accepted_at, p_delivery.delivered_at,
          p_delivery.failure_kind, p_delivery.failure_class, p_delivery.failure_rule_id,
          p_delivery.failure_reason, p_delivery.failure_attempt_no, p_delivery.failure_provider_seq,
          p_delivery.failure_occurred_at, p_delivery.failure_received_at, p_delivery.has_conflict,
          p_delivery.duplicate_delivered, p_delivery.late_event_count,
          p_delivery.projection_version, p_delivery.last_event_at, NULL::text
        )::relay_private.delivery_projection
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.projection_apply(p_state relay_private.delivery_projection,
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
      """,
      ~S"""
      CREATE FUNCTION relay_private.ledger_record(p_id uuid, p_delivery relay.deliveries,
        p_attempt_no bigint, p_actor text, p_event_type text, p_raw_code text, p_provider text,
        p_provider_seq bigint, p_occurred_at timestamptz, p_receipt_id uuid,
        p_delivery_rank smallint, p_failure_kind text, p_failure_class text,
        p_failure_rule_id text, p_failure_reason text, p_after_delivered text, p_detail jsonb,
        p_traceparent text)
        RETURNS relay_private.delivery_projection
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      DECLARE
        v_received timestamptz := clock_timestamp();
        v_other boolean := false;
        v_new relay_private.delivery_projection;
        v_effect jsonb;
      BEGIN
        IF p_delivery_rank = 2 THEN
          v_other := EXISTS (
            SELECT 1 FROM relay.delivery_events e
            WHERE e.tenant_id = p_delivery.tenant_id AND e.environment = p_delivery.environment
              AND e.delivery_id = p_delivery.id
              AND e.detail -> 'effect' ->> 'delivery_rank' = '2'
              AND e.attempt_no IS DISTINCT FROM p_attempt_no);
        END IF;
        v_new := relay_private.projection_apply(relay_private.projection_of(p_delivery),
          p_event_type, p_attempt_no, p_provider_seq, p_occurred_at, v_received, p_delivery_rank,
          p_failure_kind, p_failure_class, p_failure_rule_id, p_failure_reason, p_after_delivered,
          v_other);
        v_effect := jsonb_strip_nulls(jsonb_build_object('delivery_rank', p_delivery_rank,
          'failure_kind', p_failure_kind, 'failure_class', p_failure_class,
          'failure_rule_id', p_failure_rule_id, 'failure_reason', p_failure_reason,
          'after_delivered', p_after_delivered));
        INSERT INTO relay.delivery_events (tenant_id, environment, id, received_at, delivery_id,
          attempt_no, actor, event_type, raw_code, provider, provider_seq, occurred_at, receipt_id,
          projection_result, detail, evidence_version_id, traceparent)
        VALUES (p_delivery.tenant_id, p_delivery.environment, p_id, v_received, p_delivery.id,
          p_attempt_no, p_actor, p_event_type, p_raw_code, p_provider, p_provider_seq, p_occurred_at,
          p_receipt_id, v_new.result,
          COALESCE(p_detail, '{}'::jsonb) || jsonb_build_object('effect', v_effect), NULL,
          p_traceparent);
        UPDATE relay.deliveries d SET
            delivery_rank = v_new.delivery_rank,
            accepted_at = v_new.accepted_at,
            delivered_at = v_new.delivered_at,
            failure_kind = v_new.failure_kind,
            failure_class = v_new.failure_class,
            failure_rule_id = v_new.failure_rule_id,
            failure_reason = v_new.failure_reason,
            failure_attempt_no = v_new.failure_attempt_no,
            failure_provider_seq = v_new.failure_provider_seq,
            failure_occurred_at = v_new.failure_occurred_at,
            failure_received_at = v_new.failure_received_at,
            has_conflict = v_new.has_conflict,
            duplicate_delivered = v_new.duplicate_delivered,
            late_event_count = v_new.late_event_count,
            projection_version = v_new.projection_version,
            last_event_at = v_new.last_event_at,
            updated_at = now()
          WHERE d.tenant_id = p_delivery.tenant_id AND d.environment = p_delivery.environment
            AND d.id = p_delivery.id AND d.delivery_rank <= v_new.delivery_rank;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'invariant_violation' USING HINT = 'OP-4';
        END IF;
        RETURN v_new;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.notification_accept(p_id uuid, p_recipient_id uuid,
        p_subtenant_id uuid, p_dedup_key text, p_message_class text, p_security_subtype text,
        p_sender_type text, p_subject_type text, p_subject_id text, p_expires_at timestamptz,
        p_is_test boolean, p_traceparent text)
        RETURNS TABLE (result text, notification_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_id uuid;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        IF p_dedup_key IS NULL OR char_length(p_dedup_key) NOT BETWEEN 1 AND 512
          OR p_message_class IS NULL OR p_sender_type IS NULL OR p_is_test IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-29';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
            AND r.state = 'active') THEN
          RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF p_subtenant_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id
            AND s.state = 'active') THEN
          RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        INSERT INTO relay.notifications AS n (tenant_id, environment, id, recipient_id, subtenant_id,
          dedup_key, message_class, security_subtype, sender_type, subject_type, subject_id,
          expires_at, is_test, state, closed_at, close_rule_id, duplicate_count, last_duplicate_at,
          traceparent, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_recipient_id, p_subtenant_id, p_dedup_key, p_message_class,
          p_security_subtype, p_sender_type, p_subject_type, p_subject_id, p_expires_at, p_is_test,
          'active', NULL, NULL, 0, NULL, p_traceparent, now(), now())
        ON CONFLICT (tenant_id, environment, dedup_key, recipient_id) DO NOTHING
        RETURNING n.id INTO v_id;
        IF v_id IS NOT NULL THEN
          RETURN QUERY SELECT 'created'::text, v_id;
          RETURN;
        END IF;
        UPDATE relay.notifications n SET duplicate_count = n.duplicate_count + 1,
            last_duplicate_at = now(), updated_at = now()
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.dedup_key = p_dedup_key
            AND n.recipient_id = p_recipient_id
          RETURNING n.id INTO v_id;
        RETURN QUERY SELECT 'duplicate'::text, v_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.delivery_open(p_id uuid, p_notification_id uuid, p_channel text,
        p_target_kind text, p_target_id uuid, p_target_key bytea, p_provider text,
        p_provider_account_id uuid, p_fallback_of uuid, p_decision text, p_decision_reason text,
        p_decision_rule_id text, p_deferred_until timestamptz, p_traceparent text)
        RETURNS TABLE (result text, delivery_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_notification relay.notifications;
        v_existing uuid;
        v_event text;
        v_now timestamptz := clock_timestamp();
        v_new relay_private.delivery_projection;
        v_skip boolean := p_decision = 'skip';
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        IF p_decision IS NULL OR p_decision NOT IN ('send', 'skip', 'defer')
          OR (p_decision <> 'send' AND p_decision_rule_id IS NULL)
          OR (p_decision = 'defer') <> (p_deferred_until IS NOT NULL)
          OR p_channel IS NULL OR p_target_kind IS NULL
          OR p_target_key IS NULL OR octet_length(p_target_key) <> 32 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-1';
        END IF;
        SELECT * INTO v_notification FROM relay.notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = p_notification_id
          FOR SHARE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'notification_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT d.id INTO v_existing FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env
            AND d.notification_id = p_notification_id AND d.channel = p_channel
            AND d.target_key = p_target_key;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_existing;
          RETURN;
        END IF;
        IF v_notification.state <> 'active' THEN
          RETURN QUERY SELECT 'notification_closed'::text, NULL::uuid;
          RETURN;
        END IF;
        IF p_fallback_of IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_fallback_of
            AND d.notification_id = p_notification_id) THEN
          RETURN QUERY SELECT 'fallback_invalid'::text, NULL::uuid;
          RETURN;
        END IF;
        v_event := CASE p_decision WHEN 'send' THEN 'delivery.queued'
          WHEN 'skip' THEN 'delivery.skipped' ELSE 'delivery.deferred' END;
        v_new := relay_private.projection_apply(relay_private.projection_zero(), v_event, NULL, NULL,
          v_now, v_now, NULL,
          CASE WHEN v_skip THEN 'skipped' END, NULL,
          CASE WHEN v_skip THEN p_decision_rule_id END,
          CASE WHEN v_skip THEN p_decision_reason END,
          NULL, false);
        INSERT INTO relay.deliveries AS d (tenant_id, environment, id, notification_id, recipient_id,
          channel, target_kind, target_id, target_key, provider, provider_account_id, fallback_of,
          decision, decision_reason, decision_rule_id, deferred_until, delivery_rank, accepted_at,
          delivered_at, failure_kind, failure_class, failure_rule_id, failure_reason,
          failure_attempt_no, failure_provider_seq, failure_occurred_at, failure_received_at,
          has_conflict, duplicate_delivered, attempt_count, late_event_count, projection_version,
          last_event_at, traceparent, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_notification_id, v_notification.recipient_id, p_channel,
          p_target_kind, p_target_id, p_target_key, p_provider, p_provider_account_id, p_fallback_of,
          p_decision, p_decision_reason, p_decision_rule_id, p_deferred_until, v_new.delivery_rank,
          v_new.accepted_at, v_new.delivered_at, v_new.failure_kind, v_new.failure_class,
          v_new.failure_rule_id, v_new.failure_reason, v_new.failure_attempt_no,
          v_new.failure_provider_seq, v_new.failure_occurred_at, v_new.failure_received_at,
          v_new.has_conflict, v_new.duplicate_delivered, 0, v_new.late_event_count,
          v_new.projection_version, v_new.last_event_at, p_traceparent, now(), now())
        ON CONFLICT (tenant_id, environment, notification_id, channel, target_key) DO NOTHING
        RETURNING d.id INTO v_existing;
        IF v_existing IS NULL THEN
          SELECT d.id INTO v_existing FROM relay.deliveries d
            WHERE d.tenant_id = v_tenant AND d.environment = v_env
              AND d.notification_id = p_notification_id AND d.channel = p_channel
              AND d.target_key = p_target_key;
          RETURN QUERY SELECT 'exists'::text, v_existing;
          RETURN;
        END IF;
        INSERT INTO relay.delivery_events (tenant_id, environment, id, received_at, delivery_id,
          attempt_no, actor, event_type, raw_code, provider, provider_seq, occurred_at, receipt_id,
          projection_result, detail, evidence_version_id, traceparent)
        VALUES (v_tenant, v_env, uuidv7(), v_now, p_id, NULL, 'relay', v_event, NULL, NULL, NULL,
          v_now, NULL, v_new.result,
          jsonb_build_object('effect', jsonb_strip_nulls(jsonb_build_object(
            'failure_kind', v_new.failure_kind, 'failure_rule_id', v_new.failure_rule_id,
            'failure_reason', v_new.failure_reason))),
          NULL, p_traceparent);
        RETURN QUERY SELECT 'opened'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.delivery_cancel(p_delivery_id uuid, p_rule_id text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
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
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay', 'delivery.cancelled',
          NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL, p_rule_id, NULL, NULL, NULL,
          v_delivery.traceparent);
        PERFORM relay_private.audit_write(v_tenant, v_env, 'delivery.cancelled', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'delivery', p_delivery_id::text,
          p_rule_id, p_record_digest);
        RETURN 'cancelled';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.notification_cancel(p_notification_id uuid, p_rule_id text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, cancelled_deliveries bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_state text;
        v_delivery relay.deliveries;
        v_count bigint := 0;
      BEGIN
        IF p_rule_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-40';
        END IF;
        SELECT n.state INTO v_state FROM relay.notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = p_notification_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, 0::bigint;
          RETURN;
        END IF;
        IF v_state <> 'active' THEN
          RETURN QUERY SELECT 'already_closed'::text, 0::bigint;
          RETURN;
        END IF;
        UPDATE relay.notifications n SET state = 'cancelled', closed_at = now(),
            close_rule_id = p_rule_id, updated_at = now()
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = p_notification_id;
        FOR v_delivery IN
          SELECT * FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env
            AND d.notification_id = p_notification_id
            AND d.delivery_rank = 0 AND d.failure_kind IS NULL
          ORDER BY d.created_at, d.id
          FOR UPDATE
        LOOP
          PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
            'delivery.cancelled', NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL, p_rule_id,
            NULL, NULL, NULL, v_delivery.traceparent);
          v_count := v_count + 1;
        END LOOP;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'notification.cancelled', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'notification',
          p_notification_id::text, p_rule_id, p_record_digest);
        RETURN QUERY SELECT 'cancelled'::text, v_count;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.attempt_open(p_id uuid, p_delivery_id uuid, p_provider text,
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
      """,
      ~S"""
      CREATE FUNCTION relay_fn.attempt_start(p_delivery_id uuid, p_attempt_no bigint) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
        v_attempt relay.delivery_attempts;
      BEGIN
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        SELECT * INTO v_attempt FROM relay.delivery_attempts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.delivery_id = p_delivery_id
            AND a.attempt_no = p_attempt_no
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_attempt.state <> 'pending' THEN
          RETURN 'not_pending';
        END IF;
        UPDATE relay.delivery_attempts a SET state = 'in_flight', started_at = now(),
            updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_attempt.id
            AND a.created_at = v_attempt.created_at;
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, p_attempt_no, 'relay',
          'attempt.started', NULL, v_attempt.provider, NULL, now(), NULL, NULL, NULL, NULL, NULL,
          NULL, NULL, NULL, v_delivery.traceparent);
        RETURN 'started';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.attempt_finish(p_delivery_id uuid, p_attempt_no bigint,
        p_state text, p_failure_class text, p_raw_code text, p_provider_message_id text,
        p_event_id uuid, p_occurred_at timestamptz, p_delivery_rank smallint, p_traceparent text)
        RETURNS TABLE (result text, projection_result text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
        v_attempt relay.delivery_attempts;
        v_occurred timestamptz := COALESCE(p_occurred_at, now());
        v_new relay_private.delivery_projection;
      BEGIN
        IF p_state IS NULL OR p_state NOT IN ('succeeded', 'failed', 'unknown')
          OR (p_delivery_rank IS NOT NULL AND p_delivery_rank NOT IN (0, 1, 2))
          OR v_occurred > now() + interval '1 hour' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-31';
        END IF;
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::text;
          RETURN;
        END IF;
        SELECT * INTO v_attempt FROM relay.delivery_attempts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.delivery_id = p_delivery_id
            AND a.attempt_no = p_attempt_no
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::text;
          RETURN;
        END IF;
        IF v_attempt.state IN ('succeeded', 'failed', 'unknown') THEN
          IF v_attempt.state = p_state THEN
            RETURN QUERY SELECT 'duplicate_ignored'::text, NULL::text;
          ELSE
            RETURN QUERY SELECT 'already_terminal'::text, NULL::text;
          END IF;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_event_id);
        UPDATE relay.delivery_attempts a SET state = p_state,
            started_at = COALESCE(a.started_at, now()), finished_at = now(),
            failure_class = p_failure_class, raw_code = p_raw_code,
            provider_message_id = p_provider_message_id, updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = v_attempt.id
            AND a.created_at = v_attempt.created_at;
        v_new := relay_private.ledger_record(p_event_id, v_delivery, p_attempt_no,
          CASE WHEN p_state = 'unknown' THEN 'relay' ELSE 'provider_api' END,
          'attempt.' || p_state, p_raw_code, v_attempt.provider, NULL, v_occurred, NULL,
          p_delivery_rank, NULL, NULL, NULL, NULL, NULL, NULL, p_traceparent);
        RETURN QUERY SELECT 'applied'::text, v_new.result;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.ledger_append(p_id uuid, p_delivery_id uuid, p_attempt_no bigint,
        p_actor text, p_event_type text, p_raw_code text, p_provider text, p_provider_seq bigint,
        p_occurred_at timestamptz, p_receipt_id uuid, p_delivery_rank smallint,
        p_failure_kind text, p_failure_class text, p_failure_rule_id text, p_after_delivered text,
        p_detail jsonb, p_traceparent text)
        RETURNS TABLE (result text, delivery_rank smallint, projection_version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
        v_receipt_state text;
        v_occurred timestamptz := p_occurred_at;
        v_new relay_private.delivery_projection;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_actor IS NULL
          OR p_actor NOT IN ('relay', 'provider_api', 'provider_webhook', 'client_sdk', 'user')
          OR p_event_type IS NULL OR p_occurred_at IS NULL
          OR (p_delivery_rank IS NOT NULL AND p_delivery_rank NOT IN (0, 1, 2))
          OR (p_failure_kind IS NOT NULL
            AND p_failure_kind NOT IN ('skipped', 'failed', 'bounced', 'expired', 'cancelled'))
          OR (p_after_delivered IS NOT NULL AND p_after_delivered NOT IN ('valid', 'stale', 'conflict'))
          OR (p_detail IS NOT NULL AND jsonb_typeof(p_detail) <> 'object') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-2';
        END IF;
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'delivery_not_found'::text, NULL::smallint, NULL::bigint;
          RETURN;
        END IF;
        IF p_attempt_no IS NOT NULL
          AND (p_attempt_no < 1 OR p_attempt_no > v_delivery.attempt_count) THEN
          RETURN QUERY SELECT 'attempt_not_found'::text, v_delivery.delivery_rank,
            v_delivery.projection_version;
          RETURN;
        END IF;
        IF p_receipt_id IS NOT NULL THEN
          SELECT w.state INTO v_receipt_state FROM relay.webhook_receipts w
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_receipt_id
            FOR UPDATE;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-49';
          END IF;
          IF v_receipt_state <> 'received' THEN
            RETURN QUERY SELECT 'duplicate_ignored'::text, v_delivery.delivery_rank,
              v_delivery.projection_version;
            RETURN;
          END IF;
        END IF;
        IF p_occurred_at > now() + interval '1 hour' THEN
          IF p_actor IN ('client_sdk', 'user') THEN
            v_occurred := now();
          ELSE
            RETURN QUERY SELECT 'rejected_future_timestamp'::text, v_delivery.delivery_rank,
              v_delivery.projection_version;
            RETURN;
          END IF;
        END IF;
        IF p_receipt_id IS NOT NULL THEN
          UPDATE relay.webhook_receipts w SET state = 'processed', processed_at = now(),
              updated_at = now()
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_receipt_id;
        END IF;
        v_new := relay_private.ledger_record(p_id, v_delivery, p_attempt_no, p_actor, p_event_type,
          p_raw_code, p_provider, p_provider_seq, v_occurred, p_receipt_id, p_delivery_rank,
          p_failure_kind, p_failure_class, p_failure_rule_id, NULL, p_after_delivered, p_detail,
          p_traceparent);
        RETURN QUERY SELECT v_new.result, v_new.delivery_rank, v_new.projection_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.delivery_projection_rebuild(p_delivery_id uuid)
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
            ('last_event_at', v_delivery.last_event_at::text, s.last_event_at::text)
          ) AS c(name, stored, rebuilt)
          WHERE c.stored IS DISTINCT FROM c.rebuilt;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.subject_erase(p_recipient_id uuid, p_request_ref text,
        p_destroy_classes text[], p_restrict_classes text[], p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, cancelled_deliveries bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_state text;
        v_delivery relay.deliveries;
        v_count bigint := 0;
        v_destroy text[] := COALESCE(p_destroy_classes, ARRAY[]::text[]);
        v_restrict text[] := COALESCE(p_restrict_classes, ARRAY[]::text[]);
      BEGIN
        IF p_request_ref IS NULL OR v_destroy && v_restrict THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-18';
        END IF;
        SELECT r.state INTO v_state FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, 0::bigint;
          RETURN;
        END IF;
        IF v_state = 'deleted' THEN
          RETURN QUERY SELECT 'already_erased'::text, 0::bigint;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM relay.legal_holds h
          WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.state = 'active'
            AND (h.scope = 'tenant' OR h.recipient_id = p_recipient_id)) THEN
          RETURN QUERY SELECT 'held'::text, 0::bigint;
          RETURN;
        END IF;
        UPDATE relay.subject_keys k SET wrapped_dek = NULL, state = 'destroyed',
            destroyed_at = now(), destroy_reason = 'erasure'
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.recipient_id = p_recipient_id
            AND k.retention_class = ANY (v_destroy) AND k.state <> 'destroyed';
        UPDATE relay.subject_keys k SET state = 'restricted', restricted_at = now()
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.recipient_id = p_recipient_id
            AND k.retention_class = ANY (v_restrict) AND k.state = 'active';
        UPDATE relay.recipients r SET state = 'deleted', deleted_at = now(),
            deleted_reason = 'erasure', external_id_bidx = NULL, external_id_bidx_key_id = NULL,
            external_id_bidx_next = NULL, updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id;
        FOR v_delivery IN
          SELECT * FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.recipient_id = p_recipient_id
            AND d.delivery_rank = 0 AND d.failure_kind IS NULL
          ORDER BY d.created_at, d.id
          FOR UPDATE
        LOOP
          PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
            'delivery.cancelled', NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL,
            'subject_erasure', NULL, NULL, NULL, v_delivery.traceparent);
          v_count := v_count + 1;
        END LOOP;
        INSERT INTO relay.erasure_log (tenant_id, environment, id, recipient_id, request_ref,
          destroyed_classes, restricted_classes, cancelled_deliveries, backup_copies_expire_at,
          created_at)
        VALUES (v_tenant, v_env, uuidv7(), p_recipient_id, p_request_ref, v_destroy, v_restrict,
          v_count, now() + interval '35 days', now());
        PERFORM relay_private.audit_write(v_tenant, v_env, 'subject.erased', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'recipient', p_recipient_id::text,
          NULL, p_record_digest);
        RETURN QUERY SELECT 'erased'::text, v_count;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.webhook_receipt_record(p_id uuid, p_provider text,
        p_provider_account_id uuid, p_provider_event_id text, p_body_digest bytea,
        p_body_ct bytea, p_body_key_id uuid)
        RETURNS TABLE (result text, receipt_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_id uuid;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_provider IS NULL OR p_provider_event_id IS NULL
          OR p_body_digest IS NULL OR octet_length(p_body_digest) <> 32
          OR (p_body_ct IS NULL) <> (p_body_key_id IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-49';
        END IF;
        INSERT INTO relay.webhook_receipts AS w (tenant_id, environment, id, provider,
          provider_account_id, provider_event_id, body_digest, body_ct, body_key_id, state,
          processed_at, duplicate_count, received_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_provider, p_provider_account_id, p_provider_event_id,
          p_body_digest, p_body_ct, p_body_key_id, 'received', NULL, 0, now(), now())
        ON CONFLICT (tenant_id, environment, provider, provider_event_id) DO NOTHING
        RETURNING w.id INTO v_id;
        IF v_id IS NOT NULL THEN
          RETURN QUERY SELECT 'recorded'::text, v_id;
          RETURN;
        END IF;
        UPDATE relay.webhook_receipts w SET duplicate_count = w.duplicate_count + 1,
            updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.provider = p_provider
            AND w.provider_event_id = p_provider_event_id
          RETURNING w.id INTO v_id;
        RETURN QUERY SELECT 'duplicate'::text, v_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.webhook_receipt_mark(p_receipt_id uuid, p_state text, p_reason text)
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
        IF p_state IS NULL OR p_state NOT IN ('processed', 'rejected')
          OR (p_state = 'rejected' AND p_reason IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-49';
        END IF;
        SELECT w.state INTO v_state FROM relay.webhook_receipts w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_receipt_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state <> 'received' THEN
          RETURN 'already_final';
        END IF;
        UPDATE relay.webhook_receipts w SET state = p_state, processed_at = now(), updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_receipt_id;
        RETURN 'marked';
      END
      $fn$
      """
    ]
  end
end
