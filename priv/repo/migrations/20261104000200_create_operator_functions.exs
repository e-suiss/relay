defmodule Relay.Repo.Migrations.CreateOperatorFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @ts "timestamp with time zone"

  @functions [
    {"relay_ops.operator_sign_in(uuid, text, bytea, bytea, uuid, uuid, bytea, bytea, text, text, #{@ts}, text)",
     "relay_migrator", ~w(relay_app)},
    {"relay_ops.operator_ensure(uuid, text)", "relay_migrator", ~w(relay_app)},
    {"relay_ops.operator_session_resolve(bytea)", "relay_migrator", ~w(relay_app)},
    {"relay_ops.operator_session_step_up(uuid, #{@ts}, text, text)", "relay_migrator",
     ~w(relay_app)},
    {"relay_ops.operator_session_revoke(uuid, text)", "relay_migrator", ~w(relay_app)},
    {"relay_ops.operator_set_status(text, text, text, bytea, #{@actor})", "relay_migrator",
     ~w(relay_app)},
    {"relay_ops.operator_roles(uuid)", "relay_migrator", ~w(relay_app)},
    {"relay_ops.operator_get(uuid)", "relay_migrator", ~w(relay_app)},
    {"relay_ops.support_delegation_active(uuid, uuid, text)", "relay_migrator", ~w(relay_app)},
    {"relay_ops.tenant_overview(text, uuid, integer)", "relay_migrator", ~w(relay_app)},
    {"relay_ops.tenant_suspensions_due(integer)", "relay_migrator", ~w(relay_app)},
    {"relay_fn.role_assign(uuid, uuid, text, text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.role_revoke(uuid, text, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.support_delegation_grant(uuid, uuid, text, #{@ts}, text, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.support_delegation_revoke(uuid, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.tenant_suspension_record(uuid, uuid, text, text, #{@ts}, text, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.tenant_suspension_activate(uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.tenant_suspension_lift(uuid, text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.send_mode_set(text, text, text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)}
  ]

  # TN-19
  # TN-20
  # TN-21
  # TN-22
  # TN-23
  # TN-10
  # TN-71
  # OP-51
  # X-4
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
      CREATE FUNCTION relay_ops.operator_sign_in(p_operator_id uuid, p_access_subject text,
        p_display_name_ct bytea, p_email_ct bytea, p_field_key_id uuid, p_session_id uuid,
        p_token_digest bytea, p_csrf_digest bytea, p_client_kind text, p_access_session_ref text,
        p_auth_time timestamptz, p_acr text)
        RETURNS TABLE (result text, operator_id uuid, session_id uuid, expires_at timestamptz)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_op relay.operators;
        v_created boolean := false;
        v_expires timestamptz := now() + interval '12 hours';
      BEGIN
        IF p_operator_id IS NULL OR p_access_subject IS NULL OR p_session_id IS NULL
          OR p_token_digest IS NULL OR p_csrf_digest IS NULL OR p_auth_time IS NULL
          OR p_client_kind IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-19';
        END IF;
        SELECT * INTO v_op FROM relay.operators o
          WHERE o.access_subject = p_access_subject FOR UPDATE;
        IF NOT FOUND THEN
          INSERT INTO relay.operators (id, access_subject, display_name_ct, email_ct,
            field_key_id, status, status_changed_at, created_at, updated_at)
          VALUES (p_operator_id, p_access_subject, p_display_name_ct, p_email_ct,
            p_field_key_id, 'active', now(), now(), now())
          RETURNING * INTO v_op;
          v_created := true;
        ELSIF v_op.status = 'suspended' THEN
          RETURN QUERY SELECT 'operator_suspended'::text, v_op.id, NULL::uuid, NULL::timestamptz;
          RETURN;
        ELSIF v_op.status = 'deleted' THEN
          RETURN QUERY SELECT 'operator_deleted'::text, v_op.id, NULL::uuid, NULL::timestamptz;
          RETURN;
        END IF;
        INSERT INTO relay.operator_sessions (id, operator_id, token_digest, csrf_digest,
          client_kind, access_session_ref, auth_time, acr, step_up_at, step_up_record_ref,
          expires_at, idle_until, state, revoked_reason, created_at, updated_at)
        VALUES (p_session_id, v_op.id, p_token_digest, p_csrf_digest, p_client_kind,
          p_access_session_ref, p_auth_time, p_acr, NULL, NULL, v_expires,
          now() + interval '30 minutes', 'active', NULL, now(), now());
        IF v_created THEN
          RETURN QUERY SELECT 'created'::text, v_op.id, p_session_id, v_expires;
        ELSE
          RETURN QUERY SELECT 'signed_in'::text, v_op.id, p_session_id, v_expires;
        END IF;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.operator_ensure(p_operator_id uuid, p_access_subject text)
        RETURNS TABLE (result text, operator_id uuid, status text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_op relay.operators;
      BEGIN
        IF p_operator_id IS NULL OR p_access_subject IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-20';
        END IF;
        SELECT * INTO v_op FROM relay.operators o WHERE o.access_subject = p_access_subject;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_op.id, v_op.status;
          RETURN;
        END IF;
        INSERT INTO relay.operators (id, access_subject, display_name_ct, email_ct, field_key_id,
          status, status_changed_at, created_at, updated_at)
        VALUES (p_operator_id, p_access_subject, NULL, NULL, NULL, 'active', now(), now(), now())
        ON CONFLICT (access_subject) DO NOTHING;
        SELECT * INTO v_op FROM relay.operators o WHERE o.access_subject = p_access_subject;
        RETURN QUERY SELECT 'created'::text, v_op.id, v_op.status;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.operator_session_resolve(p_token_digest bytea)
        RETURNS TABLE (session_id uuid, operator_id uuid, operator_status text, state text,
          expires_at timestamptz, auth_time timestamptz, acr text, step_up_at timestamptz,
          step_up_record_ref text, csrf_digest bytea)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_s relay.operator_sessions;
        v_status text;
        v_state text;
      BEGIN
        SELECT * INTO v_s FROM relay.operator_sessions s
          WHERE s.token_digest = p_token_digest FOR UPDATE;
        IF NOT FOUND THEN
          RETURN;
        END IF;
        v_state := v_s.state;
        IF v_state = 'active' AND (v_s.expires_at <= now() OR v_s.idle_until <= now()) THEN
          UPDATE relay.operator_sessions s SET state = 'expired', updated_at = now()
            WHERE s.id = v_s.id;
          v_state := 'expired';
        ELSIF v_state = 'active' THEN
          UPDATE relay.operator_sessions s
            SET idle_until = least(now() + interval '30 minutes', v_s.expires_at),
              updated_at = now()
            WHERE s.id = v_s.id;
        END IF;
        SELECT o.status INTO v_status FROM relay.operators o WHERE o.id = v_s.operator_id;
        RETURN QUERY SELECT v_s.id, v_s.operator_id, v_status, v_state, v_s.expires_at,
          v_s.auth_time, v_s.acr, v_s.step_up_at, v_s.step_up_record_ref, v_s.csrf_digest::bytea;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.operator_session_step_up(p_session_id uuid,
        p_auth_time timestamptz, p_acr text, p_step_up_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_count bigint;
      BEGIN
        IF p_session_id IS NULL OR p_auth_time IS NULL OR p_step_up_record_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-21';
        END IF;
        UPDATE relay.operator_sessions s
          SET auth_time = p_auth_time, acr = p_acr, step_up_at = now(),
            step_up_record_ref = p_step_up_record_ref, updated_at = now()
          WHERE s.id = p_session_id AND s.state = 'active' AND s.expires_at > now();
        GET DIAGNOSTICS v_count = ROW_COUNT;
        IF v_count = 0 THEN
          RETURN 'session_inactive';
        END IF;
        RETURN 'recorded';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.operator_session_revoke(p_session_id uuid, p_reason text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_state text;
      BEGIN
        IF p_session_id IS NULL OR p_reason IS NULL
          OR p_reason NOT IN ('logout', 'operator_suspended', 'operator_deleted', 'admin') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-20';
        END IF;
        SELECT s.state INTO v_state FROM relay.operator_sessions s
          WHERE s.id = p_session_id FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state <> 'active' THEN
          RETURN 'already_ended';
        END IF;
        UPDATE relay.operator_sessions s
          SET state = 'revoked', revoked_reason = p_reason, updated_at = now()
          WHERE s.id = p_session_id;
        RETURN 'revoked';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.operator_set_status(p_access_subject text, p_status text,
        p_access_event_ref text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, revoked_sessions bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_op relay.operators;
        v_revoked bigint := 0;
      BEGIN
        IF p_access_subject IS NULL OR p_status IS NULL
          OR p_status NOT IN ('active', 'suspended', 'deleted') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-20';
        END IF;
        SELECT * INTO v_op FROM relay.operators o
          WHERE o.access_subject = p_access_subject FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, 0::bigint;
          RETURN;
        END IF;
        IF v_op.status = p_status OR v_op.status = 'deleted' THEN
          RETURN QUERY SELECT 'unchanged'::text, 0::bigint;
          RETURN;
        END IF;
        UPDATE relay.operators o
          SET status = p_status, status_changed_at = now(), updated_at = now(),
            display_name_ct = CASE WHEN p_status = 'deleted' THEN NULL ELSE o.display_name_ct END,
            email_ct = CASE WHEN p_status = 'deleted' THEN NULL ELSE o.email_ct END
          WHERE o.id = v_op.id;
        IF p_status <> 'active' THEN
          UPDATE relay.operator_sessions s
            SET state = 'revoked',
              revoked_reason = CASE WHEN p_status = 'deleted' THEN 'operator_deleted'
                ELSE 'operator_suspended' END,
              updated_at = now()
            WHERE s.operator_id = v_op.id AND s.state = 'active';
          GET DIAGNOSTICS v_revoked = ROW_COUNT;
          PERFORM relay_private.audit_write(relay_private.installation_tenant_id(), 'live',
            'operator_session.revoked', p_actor_kind, p_actor_ref, p_on_behalf_of_ref,
            coalesce(p_access_record_ref, p_access_event_ref), 'operator', p_access_subject,
            p_status, p_record_digest);
        END IF;
        RETURN QUERY SELECT 'changed'::text, v_revoked;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.operator_roles(p_operator_id uuid)
        RETURNS TABLE (tenant_id uuid, environment text, role text, role_assignment_id uuid)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT r.tenant_id, r.environment::text, r.role, r.id
        FROM relay.role_assignments r
        JOIN relay.operators o ON o.id = r.operator_id
        WHERE r.operator_id = p_operator_id AND r.status = 'active' AND o.status = 'active'
        ORDER BY r.tenant_id, r.environment, r.role
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.operator_get(p_operator_id uuid)
        RETURNS TABLE (id uuid, access_subject text, status text, created_at timestamptz,
          installation_assigned boolean)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT o.id, o.access_subject, o.status, o.created_at,
          EXISTS (SELECT 1 FROM relay.role_assignments r
            WHERE r.tenant_id = relay_private.installation_tenant_id()
              AND r.role = 'installation_operator')
        FROM relay.operators o
        WHERE o.id = p_operator_id
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.support_delegation_active(p_operator_id uuid, p_tenant_id uuid,
        p_environment text)
        RETURNS TABLE (delegation_id uuid, expires_at timestamptz)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT d.id, d.expires_at
        FROM relay.support_delegations d
        WHERE d.operator_id = p_operator_id AND d.tenant_id = p_tenant_id
          AND d.environment = p_environment AND d.status = 'active'
          AND d.starts_at <= now() AND d.expires_at > now()
        ORDER BY d.expires_at DESC
        LIMIT 1
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.tenant_overview(p_status text, p_after_id uuid, p_limit integer)
        RETURNS TABLE (id uuid, access_tenant_id text, region text, status text,
          api_version date, created_at timestamptz, notifications_24h bigint,
          queued_deliveries bigint, paused_deliveries bigint, active_kill_switches bigint)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT t.id, t.access_tenant_id, t.region::text, t.status, t.api_version, t.created_at,
          (SELECT count(*) FROM relay.notifications n
            WHERE n.tenant_id = t.id AND n.created_at > now() - interval '24 hours'),
          (SELECT count(*) FROM relay.deliveries d
            WHERE d.tenant_id = t.id AND d.decision = 'send' AND d.delivered_at IS NULL
              AND d.failure_kind IS NULL AND d.paused_at IS NULL),
          (SELECT count(*) FROM relay.deliveries d
            WHERE d.tenant_id = t.id AND d.paused_at IS NOT NULL AND d.failure_kind IS NULL),
          (SELECT count(*) FROM relay.kill_switches k
            WHERE k.tenant_id = t.id AND k.status = 'active'
              AND (k.expires_at IS NULL OR k.expires_at > now()))
        FROM relay.tenants t
        WHERE t.kind = 'tenant' AND (p_status IS NULL OR t.status = p_status)
          AND (p_after_id IS NULL OR t.id > p_after_id)
        ORDER BY t.id
        LIMIT least(greatest(coalesce(p_limit, 50), 1), 101)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.tenant_suspensions_due(p_limit integer)
        RETURNS TABLE (tenant_id uuid, suspension_id uuid)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT s.tenant_id, s.id
        FROM relay.tenant_suspensions s
        WHERE s.state = 'scheduled' AND s.effective_at <= now()
        ORDER BY s.effective_at
        LIMIT greatest(coalesce(p_limit, 100), 1)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.role_assign(p_id uuid, p_operator_id uuid, p_role text,
        p_reason text, p_step_up_record_ref text, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, role_assignment_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_installation boolean;
        v_status text;
        v_existing uuid;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_operator_id IS NULL OR p_role IS NULL OR p_reason IS NULL
          OR p_role NOT IN ('installation_operator', 'tenant_admin', 'tenant_operator') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-23';
        END IF;
        v_installation := v_tenant = relay_private.installation_tenant_id();
        IF (p_role = 'installation_operator') <> (v_installation AND v_env = 'live')
          OR (v_installation AND p_role <> 'installation_operator') THEN
          RETURN QUERY SELECT 'role_not_allowed'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT o.status INTO v_status FROM relay.operators o WHERE o.id = p_operator_id;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'operator_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_status <> 'active' THEN
          RETURN QUERY SELECT 'operator_inactive'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['role', p_operator_id::text, p_role]);
        SELECT r.id INTO v_existing FROM relay.role_assignments r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env
            AND r.operator_id = p_operator_id AND r.role = p_role AND r.status = 'active';
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_existing;
          RETURN;
        END IF;
        INSERT INTO relay.role_assignments (tenant_id, environment, id, operator_id, role, status,
          granted_by_ref, reason, step_up_record_ref, revoked_at, revoked_by_ref, revoke_reason,
          created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_operator_id, p_role, 'active', p_actor_ref, p_reason,
          p_step_up_record_ref, NULL, NULL, NULL, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env, 'role_assignment.created',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'role_assignment',
          p_id::text, p_reason, p_record_digest);
        RETURN QUERY SELECT 'assigned'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.role_revoke(p_role_assignment_id uuid, p_reason text,
        p_step_up_record_ref text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.role_assignments;
      BEGIN
        IF p_role_assignment_id IS NULL OR p_reason IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-21';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['role_revoke']);
        SELECT * INTO v_row FROM relay.role_assignments r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_role_assignment_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.status = 'revoked' THEN
          RETURN 'already_revoked';
        END IF;
        IF v_row.role = 'tenant_admin' AND NOT EXISTS (
          SELECT 1 FROM relay.role_assignments r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.role = 'tenant_admin'
            AND r.status = 'active' AND r.id <> v_row.id) THEN
          RETURN 'last_admin';
        END IF;
        UPDATE relay.role_assignments r
          SET status = 'revoked', revoked_at = now(), revoked_by_ref = p_actor_ref,
            revoke_reason = p_reason, updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_row.id;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'role_assignment.revoked',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'role_assignment',
          v_row.id::text, p_reason, p_record_digest);
        RETURN 'revoked';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.support_delegation_grant(p_id uuid, p_operator_id uuid,
        p_reason text, p_expires_at timestamptz, p_step_up_record_ref text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, delegation_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_status text;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_operator_id IS NULL OR p_reason IS NULL OR p_expires_at IS NULL
          OR p_step_up_record_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-23';
        END IF;
        SELECT o.status INTO v_status FROM relay.operators o WHERE o.id = p_operator_id;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'operator_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_status <> 'active' THEN
          RETURN QUERY SELECT 'not_installation_operator'::text, NULL::uuid;
          RETURN;
        END IF;
        IF p_expires_at <= now() OR p_expires_at > now() + interval '3 days' THEN
          RETURN QUERY SELECT 'duration_invalid'::text, NULL::uuid;
          RETURN;
        END IF;
        INSERT INTO relay.support_delegations (tenant_id, environment, id, operator_id, access,
          reason, granted_by_ref, step_up_record_ref, starts_at, expires_at, status, revoked_at,
          revoked_by_ref, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_operator_id, 'read', p_reason, p_actor_ref,
          p_step_up_record_ref, now(), p_expires_at, 'active', NULL, NULL, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env, 'support_delegation.granted',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'support_delegation', p_id::text, p_reason, p_record_digest);
        RETURN QUERY SELECT 'granted'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.support_delegation_revoke(p_delegation_id uuid, p_reason text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.support_delegations;
      BEGIN
        IF p_delegation_id IS NULL OR p_reason IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-23';
        END IF;
        SELECT * INTO v_row FROM relay.support_delegations d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delegation_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.status <> 'active' OR v_row.expires_at <= now() THEN
          RETURN 'already_ended';
        END IF;
        UPDATE relay.support_delegations d
          SET status = 'revoked', revoked_at = now(), revoked_by_ref = p_actor_ref,
            updated_at = now()
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = v_row.id;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'support_delegation.revoked',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'support_delegation', v_row.id::text, p_reason, p_record_digest);
        RETURN 'revoked';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.tenant_suspension_record(p_id uuid, p_subtenant_id uuid,
        p_ground text, p_reason text, p_effective_at timestamptz, p_step_up_record_ref text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, suspension_id uuid, state text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_now timestamptz := now();
        v_effective timestamptz;
        v_state text;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_ground IS NULL OR p_reason IS NULL OR p_step_up_record_ref IS NULL
          OR p_ground NOT IN ('abuse', 'security', 'legal', 'other') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-10';
        END IF;
        IF relay_private.ctx_environment() <> 'live' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-46';
        END IF;
        IF p_ground = 'other' THEN
          IF p_effective_at IS NULL OR p_effective_at < v_now + interval '7 days' THEN
            RETURN QUERY SELECT 'notice_too_short'::text, NULL::uuid, NULL::text;
            RETURN;
          END IF;
          v_effective := p_effective_at;
          v_state := 'scheduled';
        ELSE
          IF p_effective_at IS NOT NULL THEN
            RETURN QUERY SELECT 'effective_not_allowed'::text, NULL::uuid, NULL::text;
            RETURN;
          END IF;
          v_effective := v_now;
          v_state := 'effective';
        END IF;
        IF p_subtenant_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = 'live' AND s.id = p_subtenant_id
            AND s.state <> 'archived') THEN
          RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid, NULL::text;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['suspension', p_subtenant_id::text]);
        IF EXISTS (
          SELECT 1 FROM relay.tenant_suspensions x
          WHERE x.tenant_id = v_tenant AND x.environment = 'live'
            AND x.subtenant_id IS NOT DISTINCT FROM p_subtenant_id
            AND x.state IN ('scheduled', 'effective')) THEN
          RETURN QUERY SELECT 'already_suspended'::text, NULL::uuid, NULL::text;
          RETURN;
        END IF;
        INSERT INTO relay.tenant_suspensions (tenant_id, environment, id, subtenant_id, ground,
          reason, notice_due_at, effective_at, appeal_until, state, created_by_ref,
          step_up_record_ref, lifted_at, lifted_by_ref, lift_reason, created_at, updated_at)
        VALUES (v_tenant, 'live', p_id, p_subtenant_id, p_ground, p_reason,
          CASE WHEN p_ground = 'other' THEN v_now ELSE v_effective + interval '24 hours' END,
          v_effective, v_effective + interval '14 days', v_state, p_actor_ref,
          p_step_up_record_ref, NULL, NULL, NULL, v_now, v_now);
        IF v_state = 'effective' THEN
          PERFORM relay_private.suspension_apply(v_tenant, p_subtenant_id, 'suspended', p_reason);
        END IF;
        PERFORM relay_private.audit_write(v_tenant, 'live', 'tenant.suspended', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant_suspension', p_id::text,
          p_reason, p_record_digest);
        RETURN QUERY SELECT v_state, p_id, v_state;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.suspension_apply(p_tenant_id uuid, p_subtenant_id uuid,
        p_status text, p_reason text) RETURNS void
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF p_subtenant_id IS NULL THEN
          UPDATE relay.tenants t
            SET status = p_status,
              status_reason = CASE WHEN p_status = 'active' THEN NULL ELSE p_reason END,
              status_changed_at = now(), version = t.version + 1, updated_at = now()
            WHERE t.id = p_tenant_id AND t.status <> 'closed' AND t.status <> p_status;
        ELSE
          UPDATE relay.subtenants s
            SET state = p_status, version = s.version + 1, updated_at = now()
            WHERE s.tenant_id = p_tenant_id AND s.environment = 'live' AND s.id = p_subtenant_id
              AND s.state <> 'archived' AND s.state <> p_status;
        END IF;
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.suspension_apply(uuid, uuid, text, text) FROM PUBLIC",
      """
      GRANT EXECUTE ON FUNCTION relay_private.suspension_apply(uuid, uuid, text, text)
        TO relay_owner
      """,
      ~S"""
      CREATE FUNCTION relay_fn.tenant_suspension_activate(p_suspension_id uuid) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_row relay.tenant_suspensions;
      BEGIN
        IF relay_private.ctx_environment() <> 'live' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-46';
        END IF;
        SELECT * INTO v_row FROM relay.tenant_suspensions x
          WHERE x.tenant_id = v_tenant AND x.environment = 'live' AND x.id = p_suspension_id
          FOR UPDATE;
        IF NOT FOUND OR v_row.state <> 'scheduled' THEN
          RETURN 'not_scheduled';
        END IF;
        IF v_row.effective_at > now() THEN
          RETURN 'not_due';
        END IF;
        UPDATE relay.tenant_suspensions x SET state = 'effective', updated_at = now()
          WHERE x.tenant_id = v_tenant AND x.environment = 'live' AND x.id = v_row.id;
        PERFORM relay_private.suspension_apply(v_tenant, v_row.subtenant_id, 'suspended',
          v_row.reason);
        RETURN 'effective';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.tenant_suspension_lift(p_suspension_id uuid, p_reason text,
        p_step_up_record_ref text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_row relay.tenant_suspensions;
        v_state text;
      BEGIN
        IF p_suspension_id IS NULL OR p_reason IS NULL OR p_step_up_record_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-22';
        END IF;
        IF relay_private.ctx_environment() <> 'live' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-46';
        END IF;
        SELECT * INTO v_row FROM relay.tenant_suspensions x
          WHERE x.tenant_id = v_tenant AND x.environment = 'live' AND x.id = p_suspension_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.state NOT IN ('scheduled', 'effective') THEN
          RETURN 'already_ended';
        END IF;
        v_state := CASE WHEN v_row.state = 'scheduled' THEN 'cancelled' ELSE 'lifted' END;
        UPDATE relay.tenant_suspensions x
          SET state = v_state, lifted_at = now(), lifted_by_ref = p_actor_ref,
            lift_reason = p_reason, updated_at = now()
          WHERE x.tenant_id = v_tenant AND x.environment = 'live' AND x.id = v_row.id;
        IF v_state = 'lifted' THEN
          PERFORM relay_private.suspension_apply(v_tenant, v_row.subtenant_id, 'active', NULL);
        END IF;
        PERFORM relay_private.audit_write(v_tenant, 'live', 'tenant.resumed', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant_suspension',
          v_row.id::text, p_reason, p_record_digest);
        RETURN v_state;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.send_mode_set(p_category text, p_channel text, p_mode text,
        p_step_up_record_ref text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, previous text, relaxed boolean)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_key text;
        v_row relay.settings;
        v_previous text;
        v_relaxed boolean;
        v_result text;
      BEGIN
        IF (p_category IS NOT NULL AND p_channel IS NULL)
          OR (p_category IS NOT NULL AND p_category !~ '^[a-z][a-z0-9_]{0,63}$')
          OR (p_channel IS NOT NULL AND p_channel !~ '^[a-z][a-z0-9_]{0,31}$') THEN
          RETURN QUERY SELECT 'invalid_level'::text, NULL::text, false;
          RETURN;
        END IF;
        IF p_mode IS NOT NULL AND p_mode NOT IN ('live', 'shadow', 'dry_run', 'off') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-51';
        END IF;
        v_key := CASE
          WHEN p_category IS NOT NULL THEN
            'send_mode.category.' || p_category || '.channel.' || p_channel
          WHEN p_channel IS NOT NULL THEN 'send_mode.channel.' || p_channel
          ELSE 'send_mode' END;
        PERFORM relay_private.lock_scope(ARRAY['setting', NULL, v_key]);
        SELECT * INTO v_row FROM relay.settings s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.subtenant_id IS NULL
            AND s.key = v_key
          FOR UPDATE;
        IF FOUND THEN
          v_previous := v_row.value #>> '{}';
        END IF;
        IF v_previous IS NOT DISTINCT FROM p_mode THEN
          RETURN QUERY SELECT 'unchanged'::text, v_previous, false;
          RETURN;
        END IF;
        v_relaxed := CASE coalesce(p_mode, 'live') WHEN 'off' THEN 0 WHEN 'dry_run' THEN 1
            WHEN 'shadow' THEN 2 ELSE 3 END
          > CASE coalesce(v_previous, 'live') WHEN 'off' THEN 0 WHEN 'dry_run' THEN 1
            WHEN 'shadow' THEN 2 ELSE 3 END;
        IF v_row.id IS NULL THEN
          INSERT INTO relay.settings (tenant_id, environment, id, subtenant_id, key, value,
            version, created_at, updated_at)
          VALUES (v_tenant, v_env, uuidv7(), NULL, v_key, to_jsonb(p_mode), 1, now(), now());
          v_result := 'set';
        ELSE
          UPDATE relay.settings s
            SET value = CASE WHEN p_mode IS NULL THEN NULL ELSE to_jsonb(p_mode) END,
              version = s.version + 1, updated_at = now()
            WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = v_row.id;
          v_result := CASE WHEN p_mode IS NULL THEN 'cleared' ELSE 'set' END;
        END IF;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'send_mode.changed', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'setting', v_key,
          coalesce(p_mode, 'cleared'), p_record_digest);
        RETURN QUERY SELECT v_result, v_previous, v_relaxed;
      END
      $fn$
      """
    ]
  end
end
