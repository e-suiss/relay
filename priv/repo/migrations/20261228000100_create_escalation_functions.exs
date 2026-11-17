defmodule Relay.Repo.Migrations.CreateEscalationFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @time "timestamp with time zone"

  @private [
    "relay_private.escalation_tiers_check(jsonb, bigint)",
    "relay_private.waitpoint_plan_resolve(uuid[], text, bigint, jsonb, jsonb, bigint)",
    "relay_private.waitpoint_steps_next(relay.waitpoints)",
    "relay_private.waitpoint_surface_run(relay.waitpoints, uuid, #{@time})",
    "relay_private.waitpoint_invite(relay.waitpoints, uuid, text, uuid, jsonb, #{@time})",
    "relay_private.waitpoint_escalation_run(relay.waitpoints, relay.waitpoint_steps, #{@time})"
  ]

  @functions [
    "relay_fn.escalation_policy_put(uuid, uuid, text, text, jsonb, bigint, bigint, bytea, #{@actor})",
    "relay_fn.escalation_policy_archive(text, bytea, #{@actor})",
    "relay_fn.waitpoint_plan_check(uuid[], text, bigint, jsonb, jsonb, bigint)",
    "relay_fn.waitpoint_plan_pin(uuid, text, bigint, jsonb, jsonb, bigint)",
    "relay_fn.waitpoint_steps_fire(uuid)",
    "relay_fn.waitpoint_invitation_settle(uuid, text)"
  ]

  # AG-17
  # AG-12
  # AG-18
  # AG-19
  # AG-10
  # AG-63
  # AG-53
  # INV-35
  # WF-24
  # WF-43
  # OP-8
  def up do
    Enum.each(private(), &execute/1)

    for signature <- @private do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_owner")
    end

    Enum.each(policies() ++ plans() ++ timers(), &execute/1)

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp private do
    [tiers_check(), plan_resolve(), steps_next(), surface_run(), invite(), escalation_run()]
  end

  defp tiers_check do
    ~S"""
    CREATE FUNCTION relay_private.escalation_tiers_check(p_tiers jsonb, p_max_tiers bigint)
      RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tier jsonb;
      v_responder jsonb;
      v_channel jsonb;
    BEGIN
      IF p_tiers IS NULL OR jsonb_typeof(p_tiers) <> 'array' OR jsonb_array_length(p_tiers) < 1
        OR p_max_tiers IS NULL OR p_max_tiers < 1 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-17';
      END IF;
      IF jsonb_array_length(p_tiers) > p_max_tiers THEN
        RETURN 'tier_limit';
      END IF;
      FOR v_tier IN SELECT e.value FROM jsonb_array_elements(p_tiers) AS e(value) LOOP
        IF jsonb_typeof(v_tier) <> 'object'
          OR jsonb_typeof(v_tier -> 'after_ms') IS DISTINCT FROM 'number'
          OR (v_tier ->> 'after_ms')::numeric NOT BETWEEN 60000 AND 2592000000
          OR (v_tier ->> 'after_ms')::numeric <> trunc((v_tier ->> 'after_ms')::numeric)
          OR jsonb_typeof(COALESCE(v_tier -> 'add_responders', '[]'::jsonb)) <> 'array'
          OR jsonb_array_length(COALESCE(v_tier -> 'add_responders', '[]'::jsonb)) > 50
          OR jsonb_typeof(COALESCE(v_tier -> 'channels', '[]'::jsonb)) <> 'array'
          OR jsonb_typeof(COALESCE(v_tier -> 'repeat', '0'::jsonb)) <> 'number'
          OR COALESCE(v_tier ->> 'repeat', '0')::numeric NOT IN (0, 1, 2, 3, 4, 5)
          OR jsonb_typeof(COALESCE(v_tier -> 'skip_if_empty', 'true'::jsonb)) <> 'boolean' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-17';
        END IF;
        FOR v_channel IN
          SELECT c.value FROM jsonb_array_elements(COALESCE(v_tier -> 'channels', '[]'::jsonb))
            AS c(value)
        LOOP
          IF jsonb_typeof(v_channel) <> 'string' THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-17';
          END IF;
          PERFORM (v_channel #>> '{}')::relay.channel;
        END LOOP;
        FOR v_responder IN
          SELECT r.value
          FROM jsonb_array_elements(COALESCE(v_tier -> 'add_responders', '[]'::jsonb)) AS r(value)
        LOOP
          IF jsonb_typeof(v_responder) <> 'object'
            OR (v_responder ->> 'kind') IS NULL
            OR (v_responder ->> 'kind') NOT IN ('subscriber', 'agent')
            OR (v_responder ->> 'id') IS NULL THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-17';
          END IF;
          IF NOT EXISTS (SELECT 1 FROM relay.recipients r
            WHERE r.tenant_id = relay_private.ctx_tenant_id()
              AND r.environment = relay_private.ctx_environment()
              AND r.id = (v_responder ->> 'id')::uuid AND r.kind = (v_responder ->> 'kind')
              AND r.state <> 'deleted') THEN
            RETURN 'responder_not_found';
          END IF;
        END LOOP;
      END LOOP;
      RETURN 'ok';
    END
    $fn$
    """
  end

  defp plan_resolve do
    ~S"""
    CREATE FUNCTION relay_private.waitpoint_plan_resolve(p_responders uuid[], p_policy_key text,
      p_policy_version bigint, p_tiers jsonb, p_surface_policy jsonb, p_max_tiers bigint)
      RETURNS TABLE (result text, policy_ref text, tiers jsonb)
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_policy relay.escalation_policies;
      v_version bigint;
      v_tiers jsonb;
      v_ref text;
      v_check text;
      v_entry jsonb;
      v_step jsonb;
      v_surface jsonb;
      v_seen uuid[] := ARRAY[]::uuid[];
    BEGIN
      IF p_max_tiers IS NULL OR p_max_tiers < 1 OR p_responders IS NULL
        OR (p_policy_key IS NOT NULL AND p_tiers IS NOT NULL)
        OR (p_policy_key IS NULL AND p_policy_version IS NOT NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-17';
      END IF;
      IF p_policy_key IS NOT NULL THEN
        SELECT * INTO v_policy FROM relay.escalation_policies p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.key = p_policy_key
          FOR SHARE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'policy_not_found'::text, NULL::text, NULL::jsonb;
          RETURN;
        END IF;
        IF v_policy.state = 'archived' THEN
          RETURN QUERY SELECT 'policy_archived'::text, NULL::text, NULL::jsonb;
          RETURN;
        END IF;
        v_version := COALESCE(p_policy_version, v_policy.version);
        SELECT v.tiers INTO v_tiers FROM relay.escalation_policy_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.policy_id = v_policy.id
            AND v.version = v_version;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'policy_not_found'::text, NULL::text, NULL::jsonb;
          RETURN;
        END IF;
        v_ref := p_policy_key || ':' || v_version::text;
      ELSIF p_tiers IS NOT NULL THEN
        v_check := relay_private.escalation_tiers_check(p_tiers, p_max_tiers);
        IF v_check = 'responder_not_found' THEN
          RETURN QUERY SELECT 'responder_outside_set'::text, NULL::text, NULL::jsonb;
          RETURN;
        END IF;
        IF v_check <> 'ok' THEN
          RETURN QUERY SELECT v_check, NULL::text, NULL::jsonb;
          RETURN;
        END IF;
        v_tiers := p_tiers;
        v_ref := 'inline';
      END IF;
      IF v_tiers IS NOT NULL THEN
        IF jsonb_array_length(v_tiers) > p_max_tiers THEN
          RETURN QUERY SELECT 'tier_limit'::text, NULL::text, NULL::jsonb;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_tiers) AS t(value),
            jsonb_array_elements(COALESCE(t.value -> 'add_responders', '[]'::jsonb)) AS r(value)
          WHERE NOT ((r.value ->> 'id')::uuid = ANY (p_responders))) THEN
          RETURN QUERY SELECT 'responder_outside_set'::text, NULL::text, NULL::jsonb;
          RETURN;
        END IF;
      END IF;
      IF p_surface_policy IS NOT NULL THEN
        IF jsonb_typeof(p_surface_policy) <> 'array' OR jsonb_array_length(p_surface_policy) < 1
        THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-63';
        END IF;
        FOR v_entry IN SELECT e.value FROM jsonb_array_elements(p_surface_policy) AS e(value) LOOP
          IF jsonb_typeof(v_entry) <> 'object' OR (v_entry ->> 'recipient_id') IS NULL
            OR jsonb_typeof(v_entry -> 'steps') IS DISTINCT FROM 'array'
            OR jsonb_array_length(v_entry -> 'steps') NOT BETWEEN 1 AND 10
            OR (v_entry ->> 'recipient_id')::uuid = ANY (v_seen) THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-63';
          END IF;
          v_seen := v_seen || (v_entry ->> 'recipient_id')::uuid;
          IF NOT ((v_entry ->> 'recipient_id')::uuid = ANY (p_responders)) THEN
            RETURN QUERY SELECT 'surface_recipient_outside_set'::text, NULL::text, NULL::jsonb;
            RETURN;
          END IF;
          FOR v_step IN SELECT s.value FROM jsonb_array_elements(v_entry -> 'steps') AS s(value)
          LOOP
            IF jsonb_typeof(v_step) <> 'object'
              OR jsonb_typeof(v_step -> 'escalate_after_ms') IS DISTINCT FROM 'number'
              OR (v_step ->> 'escalate_after_ms')::numeric NOT BETWEEN 1000 AND 2592000000
              OR (v_step ->> 'escalate_after_ms')::numeric
                <> trunc((v_step ->> 'escalate_after_ms')::numeric)
              OR jsonb_typeof(v_step -> 'surfaces') IS DISTINCT FROM 'array'
              OR jsonb_array_length(v_step -> 'surfaces') NOT BETWEEN 1 AND 20 THEN
              RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-63';
            END IF;
            FOR v_surface IN
              SELECT x.value FROM jsonb_array_elements(v_step -> 'surfaces') AS x(value)
            LOOP
              IF jsonb_typeof(v_surface) <> 'object'
                OR ((v_surface ->> 'device_id') IS NULL) = ((v_surface ->> 'channel') IS NULL)
                OR (v_surface ->> 'channel') = 'in_app' THEN
                RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-63';
              END IF;
              PERFORM (v_surface ->> 'device_id')::uuid, (v_surface ->> 'channel')::relay.channel;
            END LOOP;
          END LOOP;
        END LOOP;
      END IF;
      RETURN QUERY SELECT 'ok'::text, v_ref, v_tiers;
    END
    $fn$
    """
  end

  defp steps_next do
    ~S"""
    CREATE FUNCTION relay_private.waitpoint_steps_next(p_waitpoint relay.waitpoints)
      RETURNS timestamptz
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_next timestamptz;
    BEGIN
      SELECT min(s.due_at) INTO v_next FROM relay.waitpoint_steps s
        WHERE s.tenant_id = p_waitpoint.tenant_id AND s.environment = p_waitpoint.environment
          AND s.waitpoint_id = p_waitpoint.id AND s.state = 'armed';
      UPDATE relay.waitpoints w SET next_escalation_at = v_next, updated_at = now()
        WHERE w.tenant_id = p_waitpoint.tenant_id AND w.environment = p_waitpoint.environment
          AND w.id = p_waitpoint.id AND w.next_escalation_at IS DISTINCT FROM v_next;
      RETURN v_next;
    END
    $fn$
    """
  end

  defp surface_run do
    ~S"""
    CREATE FUNCTION relay_private.waitpoint_surface_run(p_waitpoint relay.waitpoints,
      p_recipient_id uuid, p_now timestamptz)
      RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_step relay.waitpoint_steps;
      v_surfaces jsonb;
      v_first boolean;
      v_reached boolean;
      v_run bigint := 0;
    BEGIN
      LOOP
        SELECT * INTO v_step FROM relay.waitpoint_steps s
          WHERE s.tenant_id = p_waitpoint.tenant_id AND s.environment = p_waitpoint.environment
            AND s.waitpoint_id = p_waitpoint.id AND s.track = 'surface'
            AND s.recipient_id = p_recipient_id AND s.state = 'armed' AND s.due_at <= p_now
          ORDER BY s.ordinal
          LIMIT 1;
        EXIT WHEN NOT FOUND;
        v_run := v_run + 1;
        IF v_step.spec ? 'rest' THEN
          v_surfaces := jsonb_build_object('except', v_step.spec -> 'except');
        ELSE
          SELECT jsonb_agg(x.value ORDER BY x.n) INTO v_surfaces
            FROM jsonb_array_elements(v_step.spec -> 'surfaces') WITH ORDINALITY AS x(value, n)
            WHERE NOT (x.value ? 'device_id') OR EXISTS (SELECT 1 FROM relay.devices d
              WHERE d.tenant_id = p_waitpoint.tenant_id AND d.environment = p_waitpoint.environment
                AND d.id = (x.value ->> 'device_id')::uuid AND d.recipient_id = p_recipient_id
                AND d.state <> 'disabled' AND d.permission IN ('granted', 'provisional'));
        END IF;
        v_reached := v_surfaces IS NOT NULL;
        IF v_reached THEN
          v_first := NOT EXISTS (SELECT 1 FROM relay.waitpoint_invitations i
            WHERE i.tenant_id = p_waitpoint.tenant_id AND i.environment = p_waitpoint.environment
              AND i.waitpoint_id = p_waitpoint.id AND i.recipient_id = p_recipient_id);
          UPDATE relay.waitpoint_steps s SET state = 'fired', due_at = NULL, settled_at = p_now,
              updated_at = now()
            WHERE s.tenant_id = v_step.tenant_id AND s.environment = v_step.environment
              AND s.id = v_step.id;
          INSERT INTO relay.waitpoint_invitations (tenant_id, environment, id, waitpoint_id,
            recipient_id, step_id, source, surfaces, inbox, state, rule_id, invited_at, settled_at,
            created_at, updated_at)
          VALUES (v_step.tenant_id, v_step.environment, uuidv7(), p_waitpoint.id, p_recipient_id,
            v_step.id, 'surface', v_surfaces, v_first, 'requested', NULL, p_now, NULL, now(),
            now());
        ELSE
          UPDATE relay.waitpoint_steps s SET state = 'skipped', due_at = NULL,
              rule_id = 'waitpoint.surface_step_skipped', settled_at = p_now, updated_at = now()
            WHERE s.tenant_id = v_step.tenant_id AND s.environment = v_step.environment
              AND s.id = v_step.id;
        END IF;
        UPDATE relay.waitpoint_steps s SET state = 'armed',
            due_at = CASE WHEN v_reached THEN p_now + s.after_ms * interval '1 millisecond'
              ELSE p_now END,
            updated_at = now()
          WHERE s.tenant_id = v_step.tenant_id AND s.environment = v_step.environment
            AND s.waitpoint_id = p_waitpoint.id AND s.track = 'surface'
            AND s.recipient_id = p_recipient_id AND s.ordinal = v_step.ordinal + 1
            AND s.state = 'pending';
      END LOOP;
      RETURN v_run;
    END
    $fn$
    """
  end

  defp invite do
    ~S"""
    CREATE FUNCTION relay_private.waitpoint_invite(p_waitpoint relay.waitpoints,
      p_recipient_id uuid, p_source text, p_step_id uuid, p_surfaces jsonb, p_now timestamptz)
      RETURNS void
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_first boolean;
      v_started bigint;
    BEGIN
      v_first := NOT EXISTS (SELECT 1 FROM relay.waitpoint_invitations i
        WHERE i.tenant_id = p_waitpoint.tenant_id AND i.environment = p_waitpoint.environment
          AND i.waitpoint_id = p_waitpoint.id AND i.recipient_id = p_recipient_id);
      IF v_first THEN
        UPDATE relay.waitpoint_steps s SET state = 'armed', due_at = p_now, updated_at = now()
          WHERE s.tenant_id = p_waitpoint.tenant_id AND s.environment = p_waitpoint.environment
            AND s.waitpoint_id = p_waitpoint.id AND s.track = 'surface'
            AND s.recipient_id = p_recipient_id AND s.ordinal = 1 AND s.state = 'pending';
        GET DIAGNOSTICS v_started = ROW_COUNT;
        IF v_started > 0 THEN
          PERFORM relay_private.waitpoint_surface_run(p_waitpoint, p_recipient_id, p_now);
          RETURN;
        END IF;
      END IF;
      INSERT INTO relay.waitpoint_invitations (tenant_id, environment, id, waitpoint_id,
        recipient_id, step_id, source, surfaces, inbox, state, rule_id, invited_at, settled_at,
        created_at, updated_at)
      VALUES (p_waitpoint.tenant_id, p_waitpoint.environment, uuidv7(), p_waitpoint.id,
        p_recipient_id, p_step_id, p_source, p_surfaces, v_first, 'requested', NULL, p_now, NULL,
        now(), now());
    END
    $fn$
    """
  end

  defp escalation_run do
    ~S"""
    CREATE FUNCTION relay_private.waitpoint_escalation_run(p_waitpoint relay.waitpoints,
      p_step relay.waitpoint_steps, p_now timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_add uuid[] := ARRAY(SELECT (r.value ->> 'id')::uuid
        FROM jsonb_array_elements(COALESCE(p_step.spec -> 'add_responders', '[]'::jsonb))
          AS r(value));
      v_channels jsonb := (SELECT jsonb_agg(jsonb_build_object('channel', c.value) ORDER BY c.n)
        FROM jsonb_array_elements(COALESCE(p_step.spec -> 'channels', '[]'::jsonb))
          WITH ORDINALITY AS c(value, n));
      v_invited uuid[];
      v_targets uuid[];
      v_target uuid;
      v_result text;
    BEGIN
      v_invited := ARRAY(SELECT DISTINCT i.recipient_id FROM relay.waitpoint_invitations i
        WHERE i.tenant_id = p_waitpoint.tenant_id AND i.environment = p_waitpoint.environment
          AND i.waitpoint_id = p_waitpoint.id);
      v_targets := ARRAY(SELECT r.id FROM relay.recipients r
        WHERE r.tenant_id = p_waitpoint.tenant_id AND r.environment = p_waitpoint.environment
          AND r.state = 'active'
          AND (r.id = ANY (v_add) OR ((v_channels IS NOT NULL OR cardinality(v_add) = 0)
            AND r.id = ANY (v_invited)))
        ORDER BY r.id);
      IF cardinality(v_targets) = 0
        AND COALESCE((p_step.spec ->> 'skip_if_empty')::boolean, true) THEN
        UPDATE relay.waitpoint_steps s SET state = 'skipped', due_at = NULL,
            rule_id = 'waitpoint.escalation_tier_skipped', settled_at = p_now, updated_at = now()
          WHERE s.tenant_id = p_step.tenant_id AND s.environment = p_step.environment
            AND s.id = p_step.id;
        v_result := 'skipped';
      ELSE
        UPDATE relay.waitpoint_steps s SET state = 'fired', due_at = NULL, settled_at = p_now,
            updated_at = now()
          WHERE s.tenant_id = p_step.tenant_id AND s.environment = p_step.environment
            AND s.id = p_step.id;
        FOREACH v_target IN ARRAY v_targets LOOP
          PERFORM relay_private.waitpoint_invite(p_waitpoint, v_target, 'escalation', p_step.id,
            v_channels, p_now);
        END LOOP;
        PERFORM a.seq
          FROM relay_fn.mailbox_append(uuidv7(), p_waitpoint.waiter_mailbox_id, 'waitpoint_event',
            'waitpoint.escalated', NULL, p_waitpoint.id, NULL, NULL, NULL, NULL,
            sha256(convert_to(jsonb_build_object('waitpoint_id', p_waitpoint.id, 'event_type',
              'waitpoint.escalated', 'level', p_step.level, 'ordinal', p_step.ordinal)::text,
              'UTF8')),
            p_waitpoint.traceparent) a;
        PERFORM relay_fn.outbox_append(uuidv7(), 'waitpoint.escalated',
          'waitpoint:' || p_waitpoint.id::text,
          jsonb_build_object('waitpoint_id', p_waitpoint.id, 'kind', p_waitpoint.kind, 'level',
            p_step.level),
          p_waitpoint.traceparent);
        v_result := 'fired';
      END IF;
      UPDATE relay.waitpoint_steps s SET state = 'armed',
          due_at = p_now + s.after_ms * interval '1 millisecond', updated_at = now()
        WHERE s.tenant_id = p_step.tenant_id AND s.environment = p_step.environment
          AND s.waitpoint_id = p_waitpoint.id AND s.track = 'escalation'
          AND s.ordinal = p_step.ordinal + 1 AND s.state = 'pending';
      RETURN v_result;
    END
    $fn$
    """
  end

  defp policies do
    [
      ~S"""
      CREATE FUNCTION relay_fn.escalation_policy_put(p_id uuid, p_version_id uuid, p_key text,
        p_description text, p_tiers jsonb, p_expected_version bigint, p_max_tiers bigint,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, policy_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_policy relay.escalation_policies;
        v_check text;
        v_version bigint;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_key IS NULL OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-17';
        END IF;
        v_check := relay_private.escalation_tiers_check(p_tiers, p_max_tiers);
        IF v_check <> 'ok' THEN
          RETURN QUERY SELECT v_check, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['escalation_policy', p_key]);
        SELECT * INTO v_policy FROM relay.escalation_policies p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.key = p_key
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          IF p_expected_version IS NOT NULL THEN
            RETURN QUERY SELECT 'version_conflict'::text, NULL::uuid, NULL::bigint;
            RETURN;
          END IF;
          PERFORM relay_private.assert_new_id(p_id);
          PERFORM relay_private.assert_new_id(p_version_id);
          INSERT INTO relay.escalation_policies (tenant_id, environment, id, key, state,
            archived_at, version, created_at, updated_at)
          VALUES (v_tenant, v_env, p_id, p_key, 'active', NULL, 1, now(), now());
          INSERT INTO relay.escalation_policy_versions (tenant_id, environment, id, policy_id,
            version, description, tiers, created_by_ref, created_at)
          VALUES (v_tenant, v_env, p_version_id, p_id, 1, p_description, p_tiers, p_actor_ref,
            now());
          PERFORM relay_private.audit_write(v_tenant, v_env::text, 'escalation_policy.created',
            p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
            'escalation_policy', p_id::text, NULL, p_record_digest);
          RETURN QUERY SELECT 'created'::text, p_id, 1::bigint;
          RETURN;
        END IF;
        IF v_policy.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, v_policy.id, v_policy.version;
          RETURN;
        END IF;
        IF p_expected_version IS NULL THEN
          RETURN QUERY SELECT 'precondition_required'::text, v_policy.id, v_policy.version;
          RETURN;
        END IF;
        IF p_expected_version <> v_policy.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_policy.id, v_policy.version;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_version_id);
        UPDATE relay.escalation_policies p SET version = p.version + 1, updated_at = now()
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.id = v_policy.id
          RETURNING p.version INTO v_version;
        INSERT INTO relay.escalation_policy_versions (tenant_id, environment, id, policy_id,
          version, description, tiers, created_by_ref, created_at)
        VALUES (v_tenant, v_env, p_version_id, v_policy.id, v_version, p_description, p_tiers,
          p_actor_ref, now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'escalation_policy.updated',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'escalation_policy', v_policy.id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'versioned'::text, v_policy.id, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.escalation_policy_archive(p_key text, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_policy relay.escalation_policies;
      BEGIN
        PERFORM relay_private.lock_scope(ARRAY['escalation_policy', p_key]);
        SELECT * INTO v_policy FROM relay.escalation_policies p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.key = p_key
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_policy.state = 'archived' THEN
          RETURN QUERY SELECT 'already_archived'::text, v_policy.version;
          RETURN;
        END IF;
        UPDATE relay.escalation_policies p SET state = 'archived', archived_at = now(),
            updated_at = now()
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.id = v_policy.id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'escalation_policy.archived',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'escalation_policy', v_policy.id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'archived'::text, v_policy.version;
      END
      $fn$
      """
    ]
  end

  defp plans do
    [
      ~S"""
      CREATE FUNCTION relay_fn.waitpoint_plan_check(p_responder_ids uuid[], p_policy_key text,
        p_policy_version bigint, p_tiers jsonb, p_surface_policy jsonb, p_max_tiers bigint)
        RETURNS TABLE (result text, policy_ref text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      BEGIN
        RETURN QUERY SELECT r.result, r.policy_ref
          FROM relay_private.waitpoint_plan_resolve(COALESCE(p_responder_ids, ARRAY[]::uuid[]),
            p_policy_key, p_policy_version, p_tiers, p_surface_policy, p_max_tiers) r;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.waitpoint_plan_pin(p_waitpoint_id uuid, p_policy_key text,
        p_policy_version bigint, p_tiers jsonb, p_surface_policy jsonb, p_max_tiers bigint)
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
        v_responders uuid[];
        v_plan record;
        v_tier jsonb;
        v_level bigint;
        v_entry jsonb;
        v_step jsonb;
        v_ordinal bigint := 0;
        v_after bigint;
        v_named jsonb;
        v_introduced uuid[];
        v_responder uuid;
      BEGIN
        SELECT * INTO v_row FROM relay.waitpoints w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::timestamptz;
          RETURN;
        END IF;
        IF v_row.state <> 'open' OR v_now >= v_row.expires_at THEN
          RETURN QUERY SELECT 'not_open'::text, NULL::timestamptz;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM relay.waitpoint_steps s
            WHERE s.tenant_id = v_tenant AND s.environment = v_env
              AND s.waitpoint_id = p_waitpoint_id)
          OR EXISTS (SELECT 1 FROM relay.waitpoint_invitations i
            WHERE i.tenant_id = v_tenant AND i.environment = v_env
              AND i.waitpoint_id = p_waitpoint_id) THEN
          RETURN QUERY SELECT 'already_pinned'::text, v_row.next_escalation_at;
          RETURN;
        END IF;
        v_responders := ARRAY(SELECT s.recipient_id FROM relay.waitpoint_responders s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env
            AND s.waitpoint_id = p_waitpoint_id
          ORDER BY s.recipient_id);
        SELECT r.result, r.policy_ref, r.tiers INTO v_plan
          FROM relay_private.waitpoint_plan_resolve(v_responders, p_policy_key, p_policy_version,
            p_tiers, p_surface_policy, p_max_tiers) r;
        IF v_plan.result <> 'ok'
          OR v_plan.policy_ref IS DISTINCT FROM v_row.escalation_policy_ref THEN
          RAISE EXCEPTION 'invalid_argument'
            USING DETAIL = 'the plan does not fit the stored responders and policy reference',
              HINT = 'AG-12';
        END IF;
        FOR v_tier, v_level IN
          SELECT t.value, t.n
          FROM jsonb_array_elements(COALESCE(v_plan.tiers, '[]'::jsonb))
            WITH ORDINALITY AS t(value, n)
          ORDER BY t.n
        LOOP
          FOR v_after IN
            SELECT (v_tier ->> 'after_ms')::bigint
            FROM generate_series(0, COALESCE((v_tier ->> 'repeat')::bigint, 0))
          LOOP
            v_ordinal := v_ordinal + 1;
            INSERT INTO relay.waitpoint_steps (tenant_id, environment, id, waitpoint_id, track,
              recipient_id, ordinal, level, after_ms, spec, state, due_at, remaining_ms, rule_id,
              settled_at, created_at, updated_at)
            VALUES (v_tenant, v_env, uuidv7(), p_waitpoint_id, 'escalation', NULL, v_ordinal,
              v_level, v_after, v_tier - 'after_ms' - 'repeat',
              CASE WHEN v_ordinal = 1 THEN 'armed' ELSE 'pending' END,
              CASE WHEN v_ordinal = 1 THEN v_now + v_after * interval '1 millisecond' END, NULL,
              NULL, NULL, now(), now());
          END LOOP;
        END LOOP;
        FOR v_entry IN
          SELECT e.value
          FROM jsonb_array_elements(COALESCE(p_surface_policy, '[]'::jsonb)) AS e(value)
        LOOP
          v_ordinal := 0;
          v_after := 0;
          v_named := '[]'::jsonb;
          FOR v_step IN SELECT s.value
            FROM jsonb_array_elements(v_entry -> 'steps') WITH ORDINALITY AS s(value, n)
            ORDER BY s.n
          LOOP
            v_ordinal := v_ordinal + 1;
            INSERT INTO relay.waitpoint_steps (tenant_id, environment, id, waitpoint_id, track,
              recipient_id, ordinal, level, after_ms, spec, state, due_at, remaining_ms, rule_id,
              settled_at, created_at, updated_at)
            VALUES (v_tenant, v_env, uuidv7(), p_waitpoint_id, 'surface',
              (v_entry ->> 'recipient_id')::uuid, v_ordinal, v_ordinal, v_after,
              jsonb_build_object('surfaces', v_step -> 'surfaces'), 'pending', NULL, NULL, NULL,
              NULL, now(), now());
            v_after := (v_step ->> 'escalate_after_ms')::bigint;
            v_named := v_named || (v_step -> 'surfaces');
          END LOOP;
          INSERT INTO relay.waitpoint_steps (tenant_id, environment, id, waitpoint_id, track,
            recipient_id, ordinal, level, after_ms, spec, state, due_at, remaining_ms, rule_id,
            settled_at, created_at, updated_at)
          VALUES (v_tenant, v_env, uuidv7(), p_waitpoint_id, 'surface',
            (v_entry ->> 'recipient_id')::uuid, v_ordinal + 1, v_ordinal + 1, v_after,
            jsonb_build_object('rest', true, 'except', v_named), 'pending', NULL, NULL, NULL,
            NULL, now(), now());
        END LOOP;
        v_introduced := ARRAY(SELECT DISTINCT (r.value ->> 'id')::uuid
          FROM jsonb_array_elements(COALESCE(v_plan.tiers, '[]'::jsonb)) AS t(value),
            jsonb_array_elements(COALESCE(t.value -> 'add_responders', '[]'::jsonb)) AS r(value));
        FOREACH v_responder IN ARRAY v_responders LOOP
          IF NOT (v_responder = ANY (v_introduced)) THEN
            PERFORM relay_private.waitpoint_invite(v_row, v_responder, 'creation', NULL, NULL,
              v_now);
          END IF;
        END LOOP;
        RETURN QUERY SELECT 'pinned'::text, relay_private.waitpoint_steps_next(v_row);
      END
      $fn$
      """
    ]
  end

  defp timers do
    [
      ~S"""
      CREATE FUNCTION relay_fn.waitpoint_steps_fire(p_waitpoint_id uuid)
        RETURNS TABLE (result text, fired bigint, next_at timestamptz)
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
        v_step relay.waitpoint_steps;
        v_fired bigint := 0;
        v_next timestamptz;
      BEGIN
        SELECT * INTO v_row FROM relay.waitpoints w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_waitpoint_id
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, 0::bigint, NULL::timestamptz;
          RETURN;
        END IF;
        IF v_row.state <> 'open' OR v_now >= v_row.expires_at THEN
          RETURN QUERY SELECT 'not_open'::text, 0::bigint, NULL::timestamptz;
          RETURN;
        END IF;
        LOOP
          SELECT * INTO v_step FROM relay.waitpoint_steps s
            WHERE s.tenant_id = v_tenant AND s.environment = v_env
              AND s.waitpoint_id = p_waitpoint_id AND s.state = 'armed' AND s.due_at <= v_now
            ORDER BY s.due_at, s.track, s.ordinal, s.id
            LIMIT 1;
          EXIT WHEN NOT FOUND;
          IF v_step.track = 'escalation' THEN
            PERFORM relay_private.waitpoint_escalation_run(v_row, v_step, v_now);
          ELSE
            PERFORM relay_private.waitpoint_surface_run(v_row, v_step.recipient_id, v_now);
          END IF;
          v_fired := v_fired + 1;
        END LOOP;
        v_next := relay_private.waitpoint_steps_next(v_row);
        RETURN QUERY SELECT CASE WHEN v_fired > 0 THEN 'fired' ELSE 'not_due' END, v_fired,
          v_next;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.waitpoint_invitation_settle(p_invitation_id uuid, p_outcome text)
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
        v_waitpoint_id uuid;
        v_row relay.waitpoints;
        v_invitation relay.waitpoint_invitations;
        v_skipped bigint;
      BEGIN
        IF p_outcome IS NULL OR p_outcome NOT IN ('delivered', 'unreachable') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'AG-63';
        END IF;
        SELECT i.waitpoint_id INTO v_waitpoint_id FROM relay.waitpoint_invitations i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_invitation_id;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::timestamptz;
          RETURN;
        END IF;
        SELECT * INTO v_row FROM relay.waitpoints w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_waitpoint_id
          FOR NO KEY UPDATE;
        SELECT * INTO v_invitation FROM relay.waitpoint_invitations i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_invitation_id
          FOR NO KEY UPDATE;
        IF v_invitation.state <> 'requested' THEN
          RETURN QUERY SELECT 'already_settled'::text, v_row.next_escalation_at;
          RETURN;
        END IF;
        IF p_outcome = 'delivered' THEN
          UPDATE relay.waitpoint_invitations i SET state = 'delivered', settled_at = v_now,
              updated_at = now()
            WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_invitation_id;
          RETURN QUERY SELECT 'settled'::text, v_row.next_escalation_at;
          RETURN;
        END IF;
        UPDATE relay.waitpoint_invitations i SET state = 'unreachable',
            rule_id = CASE WHEN i.source = 'surface' THEN 'waitpoint.surface_step_skipped'
              ELSE 'waitpoint.invitation_unreachable' END,
            settled_at = v_now, updated_at = now()
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_invitation_id;
        IF v_invitation.source <> 'surface' OR v_row.state <> 'open'
          OR v_now >= v_row.expires_at THEN
          RETURN QUERY SELECT 'settled'::text, v_row.next_escalation_at;
          RETURN;
        END IF;
        UPDATE relay.waitpoint_steps s SET state = 'skipped',
            rule_id = 'waitpoint.surface_step_skipped', updated_at = now()
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = v_invitation.step_id
            AND s.state = 'fired';
        GET DIAGNOSTICS v_skipped = ROW_COUNT;
        IF v_skipped > 0 THEN
          UPDATE relay.waitpoint_steps s SET due_at = v_now, updated_at = now()
            WHERE s.tenant_id = v_tenant AND s.environment = v_env
              AND s.waitpoint_id = v_waitpoint_id AND s.track = 'surface'
              AND s.recipient_id = v_invitation.recipient_id AND s.state = 'armed';
          PERFORM relay_private.waitpoint_surface_run(v_row, v_invitation.recipient_id, v_now);
        END IF;
        RETURN QUERY SELECT 'settled'::text, relay_private.waitpoint_steps_next(v_row);
      END
      $fn$
      """
    ]
  end
end
