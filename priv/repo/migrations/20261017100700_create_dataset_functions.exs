defmodule Relay.Repo.Migrations.CreateDatasetFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.dataset_version_publish(uuid, text, jsonb, bytea, text, text, timestamp with time zone, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.dataset_activate(text, uuid, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)}
  ]

  # OP-65
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
      CREATE FUNCTION relay_fn.dataset_version_publish(p_id uuid, p_dataset_name text,
        p_content jsonb, p_content_digest bytea, p_source text, p_source_ref text,
        p_valid_from timestamptz, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version_id uuid, version_no bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_scopes text[];
        v_scope text;
        v_existing relay.dataset_versions;
        v_no bigint;
      BEGIN
        IF p_content IS NULL OR p_content_digest IS NULL OR octet_length(p_content_digest) <> 32
          OR p_source IS NULL OR p_source NOT IN ('package', 'operator')
          OR p_source_ref IS NULL OR p_valid_from IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-65';
        END IF;
        SELECT d.allowed_scopes INTO v_scopes FROM relay.datasets d WHERE d.name = p_dataset_name;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'dataset_not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        v_scope := CASE WHEN v_tenant = relay_private.installation_tenant_id()
          THEN 'installation' ELSE 'tenant' END;
        IF NOT (v_scope = ANY (v_scopes)) OR (v_scope = 'installation' AND v_env <> 'live') THEN
          RETURN QUERY SELECT 'scope_not_allowed'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['dataset', p_dataset_name]);
        SELECT * INTO v_existing FROM relay.dataset_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.dataset_name = p_dataset_name
            AND v.content_digest = p_content_digest;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_existing.id, v_existing.version_no;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        SELECT COALESCE(max(v.version_no), 0) + 1 INTO v_no FROM relay.dataset_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.dataset_name = p_dataset_name;
        INSERT INTO relay.dataset_versions (tenant_id, environment, id, dataset_name, version_no,
          content, content_digest, source, source_ref, valid_from, published_by_ref, created_at)
        VALUES (v_tenant, v_env, p_id, p_dataset_name, v_no, p_content, p_content_digest, p_source,
          p_source_ref, p_valid_from, p_actor_ref, now());
        PERFORM relay_private.audit_write(v_tenant, v_env, 'dataset.version_published',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'dataset_version',
          p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'published'::text, p_id, v_no;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.dataset_activate(p_dataset_name text, p_version_id uuid,
        p_source text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_current uuid;
        v_current_source text;
      BEGIN
        IF p_source IS NULL OR p_source NOT IN ('package', 'operator') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-65';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM relay.dataset_versions v
          WHERE v.tenant_id = v_tenant AND v.environment = v_env AND v.id = p_version_id
            AND v.dataset_name = p_dataset_name) THEN
          RETURN 'version_not_found';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['dataset', p_dataset_name]);
        SELECT a.version_id, v.source INTO v_current, v_current_source
          FROM relay.dataset_active a
          JOIN relay.dataset_versions v
            ON v.tenant_id = a.tenant_id AND v.environment = a.environment AND v.id = a.version_id
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.dataset_name = p_dataset_name
          FOR UPDATE OF a;
        IF FOUND THEN
          IF v_current = p_version_id THEN
            RETURN 'already_active';
          END IF;
          IF p_source = 'package' AND v_current_source = 'operator' THEN
            RETURN 'operator_pinned';
          END IF;
          UPDATE relay.dataset_active a SET version_id = p_version_id, activated_at = now(),
              activated_by_ref = p_actor_ref
            WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.dataset_name = p_dataset_name;
        ELSE
          INSERT INTO relay.dataset_active (tenant_id, environment, dataset_name, version_id,
            activated_at, activated_by_ref)
          VALUES (v_tenant, v_env, p_dataset_name, p_version_id, now(), p_actor_ref);
        END IF;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'dataset.activated', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'dataset_version',
          p_version_id::text, p_source, p_record_digest);
        RETURN 'activated';
      END
      $fn$
      """
    ]
  end
end
