defmodule Relay.Repo.Migrations.CreateTenancyFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_ops.tenant_create(uuid, text, text, text, text, text, bytea, #{@actor})",
     "relay_maint", ~w(relay_app)},
    {"relay_fn.tenant_set_status(text, text, bigint, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.tenant_update_defaults(text, text, text, bigint, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.subtenant_upsert(uuid, text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.subtenant_archive(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.setting_set(uuid, text, jsonb, bigint, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)}
  ]

  # OP-8
  # TN-2
  # TN-4
  # TN-10
  def up do
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
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_ops.tenant_create(p_id uuid, p_access_tenant_id text, p_region text,
        p_sector text, p_default_timezone text, p_default_locale text, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, tenant_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_region text;
        v_sector text := COALESCE(p_sector, 'general');
        v_existing relay.tenants;
        v_inserted uuid;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_access_tenant_id IS NULL OR p_region IS NULL OR p_default_timezone IS NULL
          OR p_default_locale IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-2';
        END IF;
        SELECT i.region INTO v_region FROM relay.installation i;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'invariant_violation' USING HINT = 'INV-41';
        END IF;
        IF v_region <> p_region THEN
          RETURN QUERY SELECT 'region_mismatch'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended('tenant|' || p_access_tenant_id, 0));
        INSERT INTO relay.tenants AS t (id, kind, access_tenant_id, region, sector, default_timezone,
          default_locale, status, status_reason, status_changed_at, closed_at, version, created_at,
          updated_at)
        VALUES (p_id, 'tenant', p_access_tenant_id, p_region, v_sector, p_default_timezone,
          p_default_locale, 'active', NULL, now(), NULL, 1, now(), now())
        ON CONFLICT DO NOTHING
        RETURNING t.id INTO v_inserted;
        IF v_inserted IS NULL THEN
          SELECT * INTO v_existing FROM relay.tenants t WHERE t.access_tenant_id = p_access_tenant_id;
          IF FOUND AND v_existing.kind = 'tenant'
            AND v_existing.region = p_region
            AND v_existing.sector = v_sector
            AND v_existing.default_timezone = p_default_timezone
            AND v_existing.default_locale = p_default_locale THEN
            RETURN QUERY SELECT 'exists'::text, v_existing.id;
          ELSE
            RETURN QUERY SELECT 'conflict'::text, v_existing.id;
          END IF;
          RETURN;
        END IF;
        PERFORM relay_private.audit_write(p_id, 'live', 'tenant.created', p_actor_kind, p_actor_ref,
          p_on_behalf_of_ref, p_access_record_ref, 'tenant', p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'created'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.tenant_set_status(p_status text, p_reason text,
        p_expected_version bigint, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant relay.tenants;
        v_version bigint;
      BEGIN
        IF p_status IS NULL OR p_status NOT IN ('active', 'suspended', 'closed')
          OR (p_status <> 'active' AND p_reason IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-10';
        END IF;
        IF relay_private.ctx_environment() <> 'live' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-46';
        END IF;
        SELECT * INTO v_tenant FROM relay.tenants t
          WHERE t.id = relay_private.ctx_tenant_id() FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'scope_missing' USING HINT = 'TN-13';
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_tenant.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_tenant.version;
          RETURN;
        END IF;
        IF v_tenant.status = p_status THEN
          RETURN QUERY SELECT 'unchanged'::text, v_tenant.version;
          RETURN;
        END IF;
        IF v_tenant.status = 'closed' THEN
          RETURN QUERY SELECT 'invalid_transition'::text, v_tenant.version;
          RETURN;
        END IF;
        UPDATE relay.tenants t SET status = p_status, status_reason = p_reason,
            status_changed_at = now(),
            closed_at = CASE WHEN p_status = 'closed' THEN now() END,
            version = t.version + 1, updated_at = now()
          WHERE t.id = v_tenant.id
          RETURNING t.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant.id, 'live',
          CASE p_status WHEN 'active' THEN 'tenant.reactivated' WHEN 'suspended' THEN 'tenant.suspended'
            ELSE 'tenant.closed' END,
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant',
          v_tenant.id::text, p_reason, p_record_digest);
        RETURN QUERY SELECT 'changed'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.tenant_update_defaults(p_default_timezone text, p_default_locale text,
        p_sector text, p_expected_version bigint, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant relay.tenants;
        v_version bigint;
      BEGIN
        IF relay_private.ctx_environment() <> 'live' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-46';
        END IF;
        SELECT * INTO v_tenant FROM relay.tenants t
          WHERE t.id = relay_private.ctx_tenant_id() FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'scope_missing' USING HINT = 'TN-13';
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_tenant.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_tenant.version;
          RETURN;
        END IF;
        IF COALESCE(p_default_timezone, v_tenant.default_timezone) = v_tenant.default_timezone
          AND COALESCE(p_default_locale, v_tenant.default_locale) = v_tenant.default_locale
          AND COALESCE(p_sector, v_tenant.sector) = v_tenant.sector THEN
          RETURN QUERY SELECT 'unchanged'::text, v_tenant.version;
          RETURN;
        END IF;
        UPDATE relay.tenants t SET
            default_timezone = COALESCE(p_default_timezone, t.default_timezone),
            default_locale = COALESCE(p_default_locale, t.default_locale),
            sector = COALESCE(p_sector, t.sector),
            version = t.version + 1, updated_at = now()
          WHERE t.id = v_tenant.id
          RETURNING t.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant.id, 'live', 'tenant.defaults_updated',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant',
          v_tenant.id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.subtenant_upsert(p_id uuid, p_access_organization_id text,
        p_name text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, subtenant_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.subtenants;
        v_version bigint;
      BEGIN
        IF p_id IS NULL OR uuid_extract_version(p_id) IS DISTINCT FROM 7
          OR p_access_organization_id IS NULL OR p_name IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-6';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['subtenant', p_access_organization_id]);
        SELECT * INTO v_row FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env
            AND s.access_organization_id = p_access_organization_id
          FOR UPDATE;
        IF NOT FOUND THEN
          INSERT INTO relay.subtenants (tenant_id, environment, id, access_organization_id, name,
            state, archived_at, version, created_at, updated_at)
          VALUES (v_tenant, v_env, p_id, p_access_organization_id, p_name, 'active', NULL, 1,
            now(), now());
          PERFORM relay_private.audit_write(v_tenant, v_env, 'subtenant.created', p_actor_kind,
            p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'subtenant', p_id::text, NULL,
            p_record_digest);
          RETURN QUERY SELECT 'created'::text, p_id, 1::bigint;
          RETURN;
        END IF;
        IF v_row.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, v_row.id, v_row.version;
          RETURN;
        END IF;
        IF v_row.name = p_name THEN
          RETURN QUERY SELECT 'unchanged'::text, v_row.id, v_row.version;
          RETURN;
        END IF;
        UPDATE relay.subtenants s SET name = p_name, version = s.version + 1, updated_at = now()
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = v_row.id
          RETURNING s.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'subtenant.updated', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'subtenant', v_row.id::text, NULL,
          p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_row.id, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.subtenant_archive(p_subtenant_id uuid, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
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
        SELECT s.state INTO v_state FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state = 'archived' THEN
          RETURN 'already_archived';
        END IF;
        UPDATE relay.subtenants s SET state = 'archived', archived_at = now(),
            version = s.version + 1, updated_at = now()
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'subtenant.archived', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'subtenant', p_subtenant_id::text,
          NULL, p_record_digest);
        RETURN 'archived';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.setting_set(p_subtenant_id uuid, p_key text, p_value jsonb,
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
        v_row relay.settings;
        v_version bigint;
        v_result text;
      BEGIN
        IF p_key IS NULL OR p_key !~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'
          OR char_length(p_key) > 128 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-4';
        END IF;
        IF p_subtenant_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id) THEN
          RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['setting', p_subtenant_id::text, p_key]);
        SELECT * INTO v_row FROM relay.settings s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env
            AND s.subtenant_id IS NOT DISTINCT FROM p_subtenant_id AND s.key = p_key
          FOR UPDATE;
        IF NOT FOUND THEN
          IF p_value IS NULL THEN
            RETURN QUERY SELECT 'unchanged'::text, NULL::bigint;
            RETURN;
          END IF;
          IF p_expected_version IS NOT NULL THEN
            RETURN QUERY SELECT 'version_conflict'::text, NULL::bigint;
            RETURN;
          END IF;
          INSERT INTO relay.settings (tenant_id, environment, id, subtenant_id, key, value, version,
            created_at, updated_at)
          VALUES (v_tenant, v_env, uuidv7(), p_subtenant_id, p_key, p_value, 1, now(), now());
          v_result := 'created';
          v_version := 1;
        ELSE
          IF p_expected_version IS NOT NULL AND p_expected_version <> v_row.version THEN
            RETURN QUERY SELECT 'version_conflict'::text, v_row.version;
            RETURN;
          END IF;
          IF v_row.value IS NOT DISTINCT FROM p_value THEN
            RETURN QUERY SELECT 'unchanged'::text, v_row.version;
            RETURN;
          END IF;
          UPDATE relay.settings s SET value = p_value, version = s.version + 1, updated_at = now()
            WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = v_row.id
            RETURNING s.version INTO v_version;
          v_result := CASE WHEN p_value IS NULL THEN 'cleared' ELSE 'updated' END;
        END IF;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'setting.changed', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'setting', p_key, NULL,
          p_record_digest);
        RETURN QUERY SELECT v_result, v_version;
      END
      $fn$
      """
    ]
  end
end
