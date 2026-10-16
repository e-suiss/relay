defmodule Relay.Repo.Migrations.CreateContextFunctions do
  use Ecto.Migration

  @readers ~w(relay_owner relay_app relay_maint relay_archive relay_report)
  @writers ~w(relay_owner relay_maint)

  @functions [
    {"relay_private.ctx_tenant_id()", "relay_migrator", @readers},
    {"relay_private.ctx_environment()", "relay_migrator", @readers},
    {"relay_private.installation_tenant_id()", "relay_migrator", @readers},
    {"relay_private.assert_new_id(uuid)", "relay_migrator", @writers},
    {"relay_private.tenant_status()", "relay_migrator", @writers},
    {"relay_private.lock_scope(text[])", "relay_migrator", @writers},
    {"relay_private.audit_write(uuid, text, text, text, text, text, text, text, text, text, bytea)",
     "relay_migrator", @writers},
    {"relay_fn.ctx_set(uuid, text)", "relay_owner", ~w(relay_app relay_report)},
    {"relay_fn.setting_resolve(uuid, text[])", "relay_owner", ~w(relay_app relay_report)}
  ]

  # OP-8
  # TN-13
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
      CREATE FUNCTION relay_private.ctx_tenant_id() RETURNS uuid
      LANGUAGE plpgsql STABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      BEGIN
        RETURN current_setting('relay.tenant_id')::uuid;
      EXCEPTION WHEN undefined_object OR invalid_text_representation THEN
        RAISE EXCEPTION 'scope_missing' USING HINT = 'TN-13';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.ctx_environment() RETURNS relay.environment
      LANGUAGE plpgsql STABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      BEGIN
        RETURN current_setting('relay.environment')::relay.environment;
      EXCEPTION WHEN undefined_object OR check_violation OR invalid_text_representation THEN
        RAISE EXCEPTION 'scope_missing' USING HINT = 'TN-13';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.installation_tenant_id() RETURNS uuid
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT i.installation_tenant_id FROM relay.installation i
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.assert_new_id(p_id uuid) RETURNS void
      LANGUAGE plpgsql STABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      BEGIN
        IF p_id IS NULL
          OR uuid_extract_version(p_id) IS DISTINCT FROM 7
          OR abs(extract(epoch FROM uuid_extract_timestamp(p_id) - now())) > 300 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-1';
        END IF;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.tenant_status() RETURNS text
      LANGUAGE plpgsql STABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      DECLARE
        v_status text;
      BEGIN
        SELECT t.status INTO v_status FROM relay.tenants t WHERE t.id = relay_private.ctx_tenant_id();
        IF NOT FOUND THEN
          RAISE EXCEPTION 'scope_missing' USING HINT = 'TN-13';
        END IF;
        RETURN v_status;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.lock_scope(p_parts text[]) RETURNS void
      LANGUAGE sql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT pg_advisory_xact_lock(hashtextextended(
          relay_private.ctx_tenant_id()::text || '|' || relay_private.ctx_environment()::text
            || '|' || array_to_string(p_parts, '|', ''), 0))
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.audit_write(p_tenant_id uuid, p_environment text, p_action text,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text,
        p_target_type text, p_target_id text, p_reason text, p_record_digest bytea) RETURNS uuid
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      DECLARE
        v_id uuid := uuidv7();
      BEGIN
        IF p_record_digest IS NULL OR p_actor_kind IS NULL OR p_actor_ref IS NULL
          OR p_on_behalf_of_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-48';
        END IF;
        INSERT INTO relay.audit_log (tenant_id, environment, id, created_at, action, actor_kind,
          actor_ref, on_behalf_of_ref, access_record_ref, target_type, target_id, reason,
          record_digest)
        VALUES (p_tenant_id, p_environment, v_id, now(), p_action, p_actor_kind, p_actor_ref,
          p_on_behalf_of_ref, p_access_record_ref, p_target_type, p_target_id, p_reason,
          p_record_digest);
        RETURN v_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.ctx_set(p_tenant_id uuid, p_environment text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      DECLARE
        v_status text;
      BEGIN
        IF p_tenant_id IS NULL OR p_environment IS NULL OR p_environment NOT IN ('live', 'test') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-13';
        END IF;
        PERFORM set_config('relay.tenant_id', p_tenant_id::text, true);
        PERFORM set_config('relay.environment', p_environment, true);
        SELECT t.status INTO v_status FROM relay.tenants t WHERE t.id = p_tenant_id;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'tenant_not_found' USING HINT = 'TN-15';
        END IF;
        RETURN v_status;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.setting_resolve(p_subtenant_id uuid, p_keys text[])
        RETURNS TABLE (key text, value jsonb, source text)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      AS $fn$
        SELECT k.key,
          COALESCE(s.value, t.value, d.value),
          CASE
            WHEN s.value IS NOT NULL THEN 'subtenant'
            WHEN t.value IS NOT NULL THEN 'tenant'
            WHEN d.value IS NOT NULL THEN 'tenant_defaults'
            ELSE 'none'
          END
        FROM unnest(p_keys) WITH ORDINALITY AS k(key, ord)
        LEFT JOIN relay.settings s
          ON p_subtenant_id IS NOT NULL
          AND s.tenant_id = relay_private.ctx_tenant_id()
          AND s.environment = relay_private.ctx_environment()
          AND s.subtenant_id = p_subtenant_id
          AND s.key = k.key
        LEFT JOIN relay.settings t
          ON t.tenant_id = relay_private.ctx_tenant_id()
          AND t.environment = relay_private.ctx_environment()
          AND t.subtenant_id IS NULL
          AND t.key = k.key
        LEFT JOIN LATERAL (
          SELECT CASE k.key
              WHEN 'default_timezone' THEN to_jsonb(x.default_timezone)
              WHEN 'default_locale' THEN to_jsonb(x.default_locale)
              WHEN 'sector' THEN to_jsonb(x.sector)
            END AS value
          FROM relay.tenants x
          WHERE x.id = relay_private.ctx_tenant_id()
        ) d ON true
        ORDER BY k.ord
      $fn$
      """
    ]
  end
end
