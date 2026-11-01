defmodule Relay.Repo.Migrations.AuditWorkflowLifecycle do
  use Ecto.Migration

  # API-82 (2)
  # TN-47
  # WF-5
  # WF-6
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute(workflow_create())
    execute(workflow_draft_put())
    execute(workflow_publish_request())
    execute(workflow_promote())
    execute("RESET ROLE")
  end

  defp workflow_create do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.workflow_create(p_id uuid, p_key text, p_name text,
      p_draft_id uuid, p_definition jsonb, p_definition_digest bytea, p_event_schema jsonb,
      p_message_class text, p_category text, p_record_digest bytea, p_actor_kind text,
      p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
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
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'workflow.created',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'workflow',
        p_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'created'::text, p_id, 1::bigint;
    END
    $fn$
    """
  end

  defp workflow_draft_put do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.workflow_draft_put(p_workflow_key text, p_draft_id uuid,
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
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'workflow.drafted',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'workflow_version',
        p_draft_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'replaced'::text, v_version;
    END
    $fn$
    """
  end

  defp workflow_publish_request do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.workflow_publish_request(p_workflow_key text,
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
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'workflow.publication_requested',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'workflow_version',
        v_draft.id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'pending'::text, v_draft.id;
    END
    $fn$
    """
  end

  defp workflow_promote do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.workflow_promote(p_workflow_key text, p_version_no bigint,
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
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'workflow.promoted',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'workflow_version',
        p_new_version_id::text, NULL, p_record_digest);
      RETURN QUERY SELECT 'pending'::text, p_new_version_id;
    END
    $fn$
    """
  end
end
