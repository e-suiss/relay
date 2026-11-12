defmodule Relay.Repo.Migrations.CreateWorkflowRunFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @time "timestamp with time zone"

  @functions [
    {"relay_fn.workflow_run_start(uuid, uuid, jsonb, jsonb, jsonb, text, #{@time}, text, text, #{@time})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.workflow_run_lock(uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.workflow_run_save(uuid, bigint, jsonb, jsonb, text, #{@time}, text, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.workflow_run_cancel(uuid, uuid, text, uuid[])", "relay_owner", ~w(relay_app)},
    {"relay_fn.workflow_run_due(integer)", "relay_owner", ~w(relay_app)},
    {"relay_fn.workflow_manager_set(text, text, bigint, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_ops.workflow_run_due_scopes(integer)", "relay_maint", ~w(relay_worker)}
  ]

  # WF-59 (5)
  # WF-43
  # WF-6
  # WF-4
  # API-57
  # T-24
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.workflow_run_start(p_id uuid, p_notification_id uuid,
        p_plan jsonb, p_cursor jsonb, p_step_results jsonb, p_state text,
        p_wake_at timestamptz, p_outcome text, p_rule_id text, p_started_at timestamptz)
        RETURNS TABLE (result text, run_id uuid)
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
        v_final boolean := p_state IN ('completed', 'cancelled');
      BEGIN
        IF p_id IS NULL OR p_notification_id IS NULL OR p_plan IS NULL OR p_cursor IS NULL
          OR p_step_results IS NULL OR p_state IS NULL OR p_started_at IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-59';
        END IF;
        SELECT * INTO v_notification FROM relay.notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = p_notification_id;
        IF NOT FOUND OR v_notification.workflow_id IS NULL
          OR v_notification.workflow_version_id IS NULL THEN
          RETURN QUERY SELECT 'notification_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT r.id INTO v_existing FROM relay.workflow_runs r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env
            AND r.notification_id = p_notification_id;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_existing;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.workflow_runs (tenant_id, environment, id, notification_id, workflow_id,
          workflow_version_id, plan, step_cursor, step_results, state, wake_at, outcome, rule_id,
          started_at, finished_at, version, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_notification_id, v_notification.workflow_id,
          v_notification.workflow_version_id, p_plan, p_cursor, p_step_results, p_state,
          p_wake_at, p_outcome, p_rule_id, p_started_at,
          CASE WHEN v_final THEN now() END, 1, now(), now());
        RETURN QUERY SELECT 'started'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.workflow_run_lock(p_run_id uuid)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF p_run_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-43';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['workflow_run', p_run_id::text]);
        RETURN 'locked';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.workflow_run_save(p_run_id uuid, p_expected_version bigint,
        p_cursor jsonb, p_step_results jsonb, p_state text, p_wake_at timestamptz,
        p_outcome text, p_rule_id text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_run relay.workflow_runs;
        v_version bigint;
      BEGIN
        IF p_run_id IS NULL OR p_cursor IS NULL OR p_step_results IS NULL
          OR p_state NOT IN ('running', 'waiting', 'completed') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-59';
        END IF;
        SELECT * INTO v_run FROM relay.workflow_runs r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_run_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_run.state IN ('completed', 'cancelled') THEN
          RETURN QUERY SELECT 'already_final'::text, v_run.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_run.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_run.version;
          RETURN;
        END IF;
        UPDATE relay.workflow_runs r
          SET step_cursor = p_cursor, step_results = p_step_results, state = p_state,
            wake_at = CASE WHEN p_state = 'waiting' THEN p_wake_at END,
            outcome = CASE WHEN p_state = 'completed' THEN coalesce(p_outcome, 'completed') END,
            rule_id = p_rule_id,
            finished_at = CASE WHEN p_state = 'completed' THEN now() END,
            version = r.version + 1, updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_run_id
          RETURNING r.version INTO v_version;
        RETURN QUERY SELECT 'saved'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.workflow_run_cancel(p_event_id uuid, p_notification_id uuid,
        p_cancellation_key text, p_recipient_ids uuid[])
        RETURNS bigint
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_count bigint;
      BEGIN
        IF num_nonnulls(p_event_id, p_notification_id, p_cancellation_key) <> 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-57';
        END IF;
        UPDATE relay.workflow_runs r
          SET state = 'cancelled', wake_at = NULL, outcome = 'cancelled',
            rule_id = 'cancel.request', finished_at = now(), version = r.version + 1,
            updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env
            AND r.state IN ('running', 'waiting')
            AND r.notification_id IN (
              SELECT n.id FROM relay.notifications n
              LEFT JOIN relay.events e ON e.tenant_id = n.tenant_id
                AND e.environment = n.environment AND e.id = n.event_id
              WHERE n.tenant_id = v_tenant AND n.environment = v_env
                AND (p_notification_id IS NULL OR n.id = p_notification_id)
                AND (p_event_id IS NULL OR n.event_id = p_event_id)
                AND (p_cancellation_key IS NULL OR e.cancellation_key = p_cancellation_key)
                AND (p_recipient_ids IS NULL OR n.recipient_id = ANY (p_recipient_ids)));
        GET DIAGNOSTICS v_count = ROW_COUNT;
        RETURN v_count;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.workflow_run_due(p_limit integer)
        RETURNS TABLE (run_id uuid, wake_at timestamptz)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT r.id, r.wake_at
        FROM relay.workflow_runs r
        WHERE r.tenant_id = relay_private.ctx_tenant_id()
          AND r.environment = relay_private.ctx_environment()
          AND r.state = 'waiting'
          AND r.wake_at <= relay_private.business_now()
        ORDER BY 2, 1
        LIMIT GREATEST(COALESCE(p_limit, 100), 1)
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.workflow_manager_set(p_workflow_key text, p_managed_by text,
        p_expected_version bigint, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_workflow relay.workflows;
        v_version bigint;
      BEGIN
        IF p_workflow_key IS NULL OR p_managed_by NOT IN ('panel', 'code')
          OR p_record_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-4';
        END IF;
        SELECT * INTO v_workflow FROM relay.workflows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.key = p_workflow_key
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_workflow.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_workflow.version;
          RETURN;
        END IF;
        IF v_workflow.managed_by = p_managed_by THEN
          RETURN QUERY SELECT 'unchanged'::text, v_workflow.version;
          RETURN;
        END IF;
        UPDATE relay.workflows w
          SET managed_by = p_managed_by, version = w.version + 1, updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_workflow.id
          RETURNING w.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'workflow.manager_changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'workflow',
          v_workflow.id::text, p_managed_by, p_record_digest);
        RETURN QUERY SELECT 'changed'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.workflow_run_due_scopes(p_limit integer)
        RETURNS TABLE (tenant_id uuid, environment text)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT DISTINCT r.tenant_id, r.environment::text
        FROM relay.workflow_runs r
        LEFT JOIN relay.virtual_clocks v ON v.tenant_id = r.tenant_id
          AND v.environment = r.environment
        WHERE r.state = 'waiting'
          AND r.wake_at <= now() + coalesce(v.offset_ms, 0) * interval '1 millisecond'
        LIMIT GREATEST(COALESCE(p_limit, 100), 1)
      $fn$
      """
    ]
  end
end
