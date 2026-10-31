defmodule Relay.Repo.Migrations.CreateWorkflowFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.workflow_create(uuid, text, text, uuid, jsonb, bytea, jsonb, text, text, bytea, #{@actor})",
     ~w(relay_app)},
    {"relay_fn.workflow_draft_put(text, uuid, text, jsonb, bytea, jsonb, text, text, bigint, bytea, #{@actor})",
     ~w(relay_app)},
    {"relay_fn.workflow_publish_request(text, bigint, text, bytea, #{@actor})", ~w(relay_app)},
    {"relay_fn.workflow_promote(text, bigint, uuid, bytea, #{@actor})", ~w(relay_app)},
    {"relay_fn.workflow_publish_complete(uuid, text, jsonb, bytea, #{@actor})", ~w(relay_app)},
    {"relay_fn.workflow_resolve(text)", ~w(relay_app relay_report)}
  ]

  # WF-1
  # WF-5
  # WF-6
  # WF-7
  # INV-48
  # API-69
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down do
    for {signature, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.workflow_create(p_id uuid, p_key text, p_name text, p_draft_id uuid,
        p_definition jsonb, p_definition_digest bytea, p_event_schema jsonb, p_message_class text,
        p_category text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, workflow_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_existing relay.workflows;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_key IS NULL OR p_name IS NULL OR p_definition IS NULL OR p_event_schema IS NULL
          OR p_definition_digest IS NULL OR p_message_class IS NULL OR p_category IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-1';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['workflow', p_key]);
        SELECT * INTO v_existing FROM relay.workflows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.key = p_key;
        IF FOUND THEN
          RETURN QUERY SELECT 'key_conflict'::text, v_existing.id, v_existing.version;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        PERFORM relay_private.assert_new_id(p_draft_id);
        INSERT INTO relay.workflows (tenant_id, environment, id, key, name, managed_by, state,
          published_version_id, published_version_no, version, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_key, p_name, 'panel', 'active', NULL, NULL, 1, now(),
          now());
        INSERT INTO relay.workflow_versions (tenant_id, environment, id, workflow_id, state,
          version_no, definition, definition_digest, event_schema, message_class, category,
          promoted_from_version_no, publication_errors, requested_at, published_at,
          published_by_ref, created_at, updated_at)
        VALUES (v_tenant, v_env, p_draft_id, p_id, 'draft', NULL, p_definition,
          p_definition_digest, p_event_schema, p_message_class, p_category, NULL, NULL, NULL,
          NULL, NULL, now(), now());
        RETURN QUERY SELECT 'created'::text, p_id, 1::bigint;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.workflow_draft_put(p_workflow_key text, p_draft_id uuid,
        p_name text, p_definition jsonb, p_definition_digest bytea, p_event_schema jsonb,
        p_message_class text, p_category text, p_expected_version bigint, p_record_digest bytea,
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
        v_workflow relay.workflows;
        v_draft relay.workflow_versions;
        v_version bigint;
      BEGIN
        IF p_name IS NULL OR p_definition IS NULL OR p_event_schema IS NULL
          OR p_definition_digest IS NULL OR p_message_class IS NULL OR p_category IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-1';
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
        SELECT * INTO v_draft FROM relay.workflow_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.workflow_id = v_workflow.id
            AND v.state = 'draft'
          FOR UPDATE;
        IF FOUND AND v_draft.definition_digest = p_definition_digest
          AND v_workflow.name = p_name THEN
          RETURN QUERY SELECT 'unchanged'::text, v_workflow.version;
          RETURN;
        END IF;
        IF FOUND THEN
          UPDATE relay.workflow_versions v SET state = 'discarded', updated_at = now()
            WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = v_draft.id;
        END IF;
        PERFORM relay_private.assert_new_id(p_draft_id);
        INSERT INTO relay.workflow_versions (tenant_id, environment, id, workflow_id, state,
          version_no, definition, definition_digest, event_schema, message_class, category,
          promoted_from_version_no, publication_errors, requested_at, published_at,
          published_by_ref, created_at, updated_at)
        VALUES (v_tenant, v_env, p_draft_id, v_workflow.id, 'draft', NULL, p_definition,
          p_definition_digest, p_event_schema, p_message_class, p_category, NULL, NULL, NULL,
          NULL, NULL, now(), now());
        UPDATE relay.workflows w SET name = p_name, version = w.version + 1, updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_workflow.id
          RETURNING w.version INTO v_version;
        RETURN QUERY SELECT 'replaced'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.workflow_publish_request(p_workflow_key text,
        p_expected_version bigint, p_note text, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_workflow relay.workflows;
        v_draft relay.workflow_versions;
        v_pending uuid;
      BEGIN
        SELECT * INTO v_workflow FROM relay.workflows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.key = p_workflow_key
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_workflow.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT v.id INTO v_pending FROM relay.workflow_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.workflow_id = v_workflow.id
            AND v.state = 'pending';
        IF FOUND THEN
          RETURN QUERY SELECT 'already_pending'::text, v_pending;
          RETURN;
        END IF;
        SELECT * INTO v_draft FROM relay.workflow_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.workflow_id = v_workflow.id
            AND v.state = 'draft'
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'no_draft'::text, NULL::uuid;
          RETURN;
        END IF;
        UPDATE relay.workflow_versions v SET state = 'pending', requested_at = now(),
            published_by_ref = p_actor_ref, updated_at = now()
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = v_draft.id;
        UPDATE relay.workflows w SET version = w.version + 1, updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_workflow.id;
        RETURN QUERY SELECT 'pending'::text, v_draft.id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.workflow_promote(p_workflow_key text, p_version_no bigint,
        p_new_version_id uuid, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_workflow relay.workflows;
        v_source relay.workflow_versions;
        v_pending uuid;
      BEGIN
        SELECT * INTO v_workflow FROM relay.workflows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.key = p_workflow_key
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT * INTO v_source FROM relay.workflow_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.workflow_id = v_workflow.id
            AND v.state = 'published' AND v.version_no = p_version_no;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'version_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT v.id INTO v_pending FROM relay.workflow_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.workflow_id = v_workflow.id
            AND v.state = 'pending';
        IF FOUND THEN
          RETURN QUERY SELECT 'already_pending'::text, v_pending;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_new_version_id);
        INSERT INTO relay.workflow_versions (tenant_id, environment, id, workflow_id, state,
          version_no, definition, definition_digest, event_schema, message_class, category,
          promoted_from_version_no, publication_errors, requested_at, published_at,
          published_by_ref, created_at, updated_at)
        VALUES (v_tenant, v_env, p_new_version_id, v_workflow.id, 'pending', NULL,
          v_source.definition, v_source.definition_digest, v_source.event_schema,
          v_source.message_class, v_source.category, v_source.version_no, NULL, now(), NULL,
          p_actor_ref, now(), now());
        UPDATE relay.workflows w SET version = w.version + 1, updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_workflow.id;
        RETURN QUERY SELECT 'pending'::text, p_new_version_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.workflow_publish_complete(p_version_id uuid, p_outcome text,
        p_errors jsonb, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version_no bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_version relay.workflow_versions;
        v_no bigint;
      BEGIN
        IF p_outcome IS NULL OR p_outcome NOT IN ('published', 'rejected') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-6';
        END IF;
        SELECT * INTO v_version FROM relay.workflow_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = p_version_id;
        IF NOT FOUND OR v_version.state <> 'pending' THEN
          RETURN QUERY SELECT 'not_pending'::text, NULL::bigint;
          RETURN;
        END IF;
        PERFORM 1 FROM relay.workflows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_version.workflow_id
          FOR UPDATE;
        SELECT * INTO v_version FROM relay.workflow_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = p_version_id
          FOR UPDATE;
        IF v_version.state <> 'pending' THEN
          RETURN QUERY SELECT 'not_pending'::text, NULL::bigint;
          RETURN;
        END IF;
        IF p_outcome = 'rejected' THEN
          UPDATE relay.workflow_versions v SET state = 'rejected',
              publication_errors = COALESCE(p_errors, '[]'::jsonb), updated_at = now()
            WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = p_version_id;
          UPDATE relay.workflows w SET version = w.version + 1, updated_at = now()
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_version.workflow_id;
          RETURN QUERY SELECT 'rejected'::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT COALESCE(max(v.version_no), 0) + 1 INTO v_no FROM relay.workflow_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env
            AND v.workflow_id = v_version.workflow_id;
        UPDATE relay.workflow_versions v SET state = 'published', version_no = v_no,
            published_at = now(), publication_errors = p_errors, updated_at = now()
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = p_version_id;
        UPDATE relay.workflows w SET published_version_id = p_version_id,
            published_version_no = v_no, version = w.version + 1, updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_version.workflow_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'workflow.published',
          p_actor_kind, p_actor_ref, COALESCE(v_version.published_by_ref, p_on_behalf_of_ref),
          p_access_record_ref, 'workflow_version', p_version_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'published'::text, v_no;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.workflow_resolve(p_workflow_key text)
        RETURNS TABLE (workflow_id uuid, version_id uuid, version_no bigint, event_schema jsonb,
          message_class text, definition jsonb)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT w.id, v.id, v.version_no, v.event_schema, v.message_class::text, v.definition
        FROM relay.workflows w
        JOIN relay.workflow_versions v ON v.tenant_id = w.tenant_id
          AND v.environment = w.environment AND v.id = w.published_version_id
        WHERE w.tenant_id = relay_private.ctx_tenant_id()
          AND w.environment = relay_private.ctx_environment()
          AND w.key = p_workflow_key AND w.state = 'active'
      $fn$
      """
    ]
  end
end
