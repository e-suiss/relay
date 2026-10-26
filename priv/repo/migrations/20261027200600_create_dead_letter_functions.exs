defmodule Relay.Repo.Migrations.CreateDeadLetterFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.dead_letter_record(uuid, uuid, text, text, text, boolean, text, uuid)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.dead_letter_replay(uuid, uuid, text, text, text, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.dead_letter_close(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.dead_letter_replay_finish(uuid, boolean)", "relay_owner", ~w(relay_app)},
    {"relay_fn.dead_letter_list(text[], text[], text, uuid, integer)", "relay_owner",
     ~w(relay_app relay_report)},
    {"relay_fn.dead_letter_auto_replay_candidates(text, timestamp with time zone, integer)",
     "relay_owner", ~w(relay_app)},
    {"relay_ops.dead_letter_auto_replay_scopes(text, timestamp with time zone, integer)",
     "relay_maint", []}
  ]

  # T-29
  # INV-3
  # INV-14
  # OP-65 (4)
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.dead_letter_record(p_id uuid, p_delivery_id uuid, p_dlq_class text,
        p_failure_class text, p_raw_code text, p_invalidates_target boolean,
        p_entry_rule_id text, p_channel_parameters_version_id uuid)
        RETURNS TABLE (result text, dead_letter_id uuid)
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
        v_open uuid;
        v_first timestamptz;
        v_last timestamptz;
        v_now timestamptz := now();
        v_detail jsonb;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_dlq_class IS NULL OR p_failure_class IS NULL OR p_invalidates_target IS NULL
          OR p_entry_rule_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-29';
        END IF;
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'delivery_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT l.id INTO v_open FROM relay.dead_letters l
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.delivery_id = p_delivery_id
            AND l.state IN ('open', 'replaying')
          ORDER BY l.created_at DESC
          LIMIT 1;
        IF FOUND THEN
          RETURN QUERY SELECT 'already_open'::text, v_open;
          RETURN;
        END IF;
        IF v_delivery.failure_kind IS NOT NULL OR v_delivery.delivery_rank > 0 THEN
          RETURN QUERY SELECT 'delivery_terminal'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_delivery.attempt_count < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-29';
        END IF;
        SELECT * INTO v_notification FROM relay.notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env
            AND n.id = v_delivery.notification_id;
        SELECT min(COALESCE(a.started_at, a.created_at)),
            max(COALESCE(a.finished_at, a.started_at, a.created_at))
          INTO v_first, v_last
          FROM relay.delivery_attempts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.delivery_id = p_delivery_id;
        INSERT INTO relay.dead_letters (tenant_id, environment, id, created_at, delivery_id,
          notification_id, recipient_id, channel, provider, provider_account_id, message_class,
          dlq_class, failure_class, invalidates_target, raw_code, attempt_count, first_attempt_at,
          last_attempt_at, target_key, expires_at, entry_rule_id, channel_parameters_version_id,
          replay_depth, replay_of_id, replay_of_created_at, state, close_reason,
          replay_requested_at, replay_actor_kind, replay_actor_ref, replay_approval_ref,
          replay_cause_fixed_ref, replay_attempt_no, replay_idempotency_key, state_changed_at,
          updated_at)
        VALUES (v_tenant, v_env, p_id, v_now, p_delivery_id, v_delivery.notification_id,
          v_delivery.recipient_id, v_delivery.channel, v_delivery.provider,
          v_delivery.provider_account_id, v_notification.message_class, p_dlq_class,
          p_failure_class, p_invalidates_target, p_raw_code, v_delivery.attempt_count,
          COALESCE(v_first, v_now), GREATEST(COALESCE(v_last, v_now), COALESCE(v_first, v_now)),
          v_delivery.target_key, v_notification.expires_at, p_entry_rule_id,
          p_channel_parameters_version_id, v_delivery.replay_depth,
          v_delivery.replay_dead_letter_id, v_delivery.replay_dead_letter_created_at, 'open',
          NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, v_now, v_now);
        v_detail := jsonb_build_object('dead_letter_id', p_id, 'dead_letter_created_at', v_now,
          'dlq_class', p_dlq_class);
        IF p_channel_parameters_version_id IS NOT NULL THEN
          v_detail := v_detail || jsonb_build_object('dataset_versions',
            jsonb_build_object('channel_parameters', p_channel_parameters_version_id));
        END IF;
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, v_delivery.attempt_count, 'relay',
          'delivery.dead_lettered', p_raw_code, v_delivery.provider, NULL, v_now, NULL, NULL,
          'failed', p_failure_class, p_entry_rule_id, NULL, NULL, v_detail,
          v_delivery.traceparent);
        RETURN QUERY SELECT 'recorded'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.dead_letter_replay(p_dead_letter_id uuid, p_attempt_id uuid,
        p_replay_idempotency_key text, p_approval_ref text, p_cause_fixed_ref text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, attempt_no bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_letter relay.dead_letters;
        v_delivery relay.deliveries;
        v_no bigint;
        v_now timestamptz := now();
        v_system boolean := p_actor_kind = 'system';
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::bigint;
          RETURN;
        END IF;
        IF p_actor_kind IS NULL OR p_actor_ref IS NULL OR p_replay_idempotency_key IS NULL
          OR p_replay_idempotency_key !~ '^rpl_[0-9a-f]{32}$'
          OR (NOT v_system AND p_record_digest IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-29';
        END IF;
        PERFORM relay_private.assert_new_id(p_attempt_id);
        SELECT * INTO v_letter FROM relay.dead_letters l
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.id = p_dead_letter_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_letter.state <> 'open' THEN
          RETURN QUERY SELECT 'not_open'::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT * INTO v_delivery FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = v_letter.delivery_id
          FOR NO KEY UPDATE;
        IF v_letter.invalidates_target THEN
          UPDATE relay.dead_letters l SET state = 'closed', close_reason = 'not_replayable',
              state_changed_at = v_now, updated_at = v_now
            WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.id = p_dead_letter_id
              AND l.created_at = v_letter.created_at;
          RETURN QUERY SELECT 'not_replayable'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_letter.replay_depth = 1 THEN
          RETURN QUERY SELECT 'depth_exceeded'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_letter.dlq_class = 'quality_alarm' AND p_approval_ref IS NULL THEN
          RETURN QUERY SELECT 'approval_required'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_letter.dlq_class = 'permanent' AND p_cause_fixed_ref IS NULL THEN
          RETURN QUERY SELECT 'cause_fix_required'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_letter.expires_at IS NOT NULL AND v_letter.expires_at <= v_now THEN
          UPDATE relay.dead_letters l SET state = 'closed', close_reason = 'expired',
              state_changed_at = v_now, updated_at = v_now
            WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.id = p_dead_letter_id
              AND l.created_at = v_letter.created_at;
          IF v_delivery.delivery_rank = 0 AND v_delivery.failure_kind = 'failed' THEN
            PERFORM relay_private.ledger_record(uuidv7(), v_delivery, v_delivery.attempt_count,
              'relay', 'delivery.expired', NULL, NULL, NULL, v_now, NULL, NULL, 'expired', NULL,
              'dead_letter.expired', NULL, NULL,
              jsonb_build_object('dead_letter_id', p_dead_letter_id), v_delivery.traceparent);
          END IF;
          RETURN QUERY SELECT 'expired'::text, NULL::bigint;
          RETURN;
        END IF;
        UPDATE relay.dead_letters l SET state = 'replaying', replay_requested_at = v_now,
            replay_actor_kind = p_actor_kind, replay_actor_ref = p_actor_ref,
            replay_approval_ref = p_approval_ref, replay_cause_fixed_ref = p_cause_fixed_ref,
            replay_attempt_no = v_delivery.attempt_count + 1,
            replay_idempotency_key = p_replay_idempotency_key, state_changed_at = v_now,
            updated_at = v_now
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.id = p_dead_letter_id
            AND l.created_at = v_letter.created_at;
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
          'delivery.replay_opened', NULL, NULL, NULL, v_now, NULL, NULL, NULL, NULL, NULL, NULL,
          NULL, jsonb_build_object('dead_letter_id', p_dead_letter_id, 'dead_letter_created_at',
            v_letter.created_at),
          v_delivery.traceparent);
        UPDATE relay.deliveries d SET replay_depth = 1, replay_dead_letter_id = p_dead_letter_id,
            replay_dead_letter_created_at = v_letter.created_at,
            attempt_count = d.attempt_count + 1, updated_at = v_now
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = v_letter.delivery_id
          RETURNING d.attempt_count INTO v_no;
        INSERT INTO relay.delivery_attempts (tenant_id, environment, id, created_at, delivery_id,
          attempt_no, state, started_at, finished_at, provider, provider_account_id,
          provider_idempotency_key, provider_message_id, failure_class, raw_code, updated_at)
        VALUES (v_tenant, v_env, p_attempt_id, v_now, v_letter.delivery_id, v_no, 'pending', NULL,
          NULL, v_delivery.provider, v_delivery.provider_account_id, p_replay_idempotency_key,
          NULL, NULL, NULL, v_now);
        IF NOT v_system THEN
          PERFORM relay_private.audit_write(v_tenant, v_env, 'dead_letter.replayed',
            p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'dead_letter',
            p_dead_letter_id::text, NULL, p_record_digest);
        END IF;
        RETURN QUERY SELECT 'replay_opened'::text, v_no;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.dead_letter_close(p_dead_letter_id uuid, p_reason text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_letter relay.dead_letters;
      BEGIN
        IF p_reason IS NULL
          OR p_reason NOT IN ('expired', 'not_replayable', 'operator', 'replay_failed')
          OR (p_reason = 'operator' AND p_record_digest IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-29';
        END IF;
        SELECT * INTO v_letter FROM relay.dead_letters l
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.id = p_dead_letter_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_letter.state <> 'open' THEN
          RETURN 'not_open';
        END IF;
        UPDATE relay.dead_letters l SET state = 'closed', close_reason = p_reason,
            state_changed_at = now(), updated_at = now()
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.id = p_dead_letter_id
            AND l.created_at = v_letter.created_at;
        IF p_reason = 'operator' THEN
          PERFORM relay_private.audit_write(v_tenant, v_env, 'dead_letter.closed', p_actor_kind,
            p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'dead_letter',
            p_dead_letter_id::text, p_reason, p_record_digest);
        END IF;
        RETURN 'closed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.dead_letter_replay_finish(p_dead_letter_id uuid,
        p_succeeded boolean) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_letter relay.dead_letters;
      BEGIN
        IF p_succeeded IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-29';
        END IF;
        SELECT * INTO v_letter FROM relay.dead_letters l
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.id = p_dead_letter_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_letter.state <> 'replaying' THEN
          RETURN 'not_replaying';
        END IF;
        UPDATE relay.dead_letters l SET state = 'replayed', state_changed_at = now(),
            updated_at = now()
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.id = p_dead_letter_id
            AND l.created_at = v_letter.created_at;
        RETURN 'replayed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.dead_letter_list(p_states text[], p_dlq_classes text[],
        p_channel text, p_after_id uuid, p_limit integer)
        RETURNS SETOF relay.dead_letters
      LANGUAGE plpgsql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-29';
        END IF;
        RETURN QUERY
          SELECT * FROM relay.dead_letters l
          WHERE l.tenant_id = v_tenant AND l.environment = v_env
            AND (p_states IS NULL OR l.state = ANY (p_states))
            AND (p_dlq_classes IS NULL OR l.dlq_class = ANY (p_dlq_classes))
            AND (p_channel IS NULL OR l.channel = p_channel)
            AND (p_after_id IS NULL OR l.id > p_after_id)
          ORDER BY l.id
          LIMIT p_limit;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.dead_letter_auto_replay_candidates(p_provider text,
        p_since timestamptz, p_limit integer)
        RETURNS TABLE (dead_letter_id uuid)
      LANGUAGE plpgsql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        IF p_provider IS NULL OR p_since IS NULL OR p_limit IS NULL
          OR p_limit NOT BETWEEN 1 AND 1000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-29';
        END IF;
        RETURN QUERY
          SELECT l.id FROM relay.dead_letters l
          WHERE l.tenant_id = v_tenant AND l.environment = v_env AND l.state = 'open'
            AND l.dlq_class = 'exhausted' AND l.provider = p_provider AND l.created_at >= p_since
          ORDER BY l.created_at, l.id
          LIMIT p_limit;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.dead_letter_auto_replay_scopes(p_provider text,
        p_since timestamptz, p_limit integer)
        RETURNS TABLE (tenant_id uuid, environment text, candidates bigint)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT l.tenant_id, l.environment::text, count(*)
        FROM relay.dead_letters l
        WHERE l.state = 'open' AND l.dlq_class = 'exhausted' AND l.provider = p_provider
          AND l.created_at >= p_since
        GROUP BY l.tenant_id, l.environment
        ORDER BY l.tenant_id, l.environment
        LIMIT LEAST(GREATEST(p_limit, 1), 1000)
      $fn$
      """
    ]
  end
end
