defmodule Relay.Repo.Migrations.CreateRouteFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @settings "interval, bigint, interval, text"

  @old_category_create "relay_fn.category_create(uuid, text, text, text, boolean, boolean, jsonb, #{@settings}, boolean, bytea, #{@actor})"
  @old_category_update "relay_fn.category_update(text, text, boolean, boolean, jsonb, #{@settings}, boolean, bigint, bytea, #{@actor})"

  @functions [
    "relay_fn.route_create(uuid, text, text, jsonb, bytea, #{@actor})",
    "relay_fn.route_replace(text, text, jsonb, bigint, bytea, #{@actor})",
    "relay_fn.route_archive(text, bytea, #{@actor})",
    "relay_fn.category_create(uuid, text, text, text, boolean, boolean, jsonb, #{@settings}, boolean, text, bytea, #{@actor})",
    "relay_fn.category_update(text, text, boolean, boolean, jsonb, #{@settings}, boolean, text, bigint, bytea, #{@actor})"
  ]

  # WF-13
  # WF-14
  # WF-59
  # PC-57 (1)
  # OP-8
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute("DROP FUNCTION #{@old_category_create}")
    execute("DROP FUNCTION #{@old_category_update}")
    execute("RESET ROLE")
    execute(route_check())
    execute("REVOKE ALL ON FUNCTION relay_private.route_check(text) FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION relay_private.route_check(text) TO relay_owner")
    Enum.each(statements(), &execute/1)

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp route_check do
    ~S"""
    CREATE FUNCTION relay_private.route_check(p_key text) RETURNS text
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_state text;
    BEGIN
      IF p_key IS NULL THEN
        RETURN 'ok';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['route', p_key]);
      SELECT r.state INTO v_state FROM relay.routes r
        WHERE r.tenant_id = relay_private.ctx_tenant_id()
          AND r.environment = relay_private.ctx_environment() AND r.key = p_key;
      IF NOT FOUND THEN
        RETURN 'route_not_found';
      END IF;
      IF v_state = 'archived' THEN
        RETURN 'route_archived';
      END IF;
      RETURN 'ok';
    END
    $fn$
    """
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.route_create(p_id uuid, p_key text, p_name text, p_tree jsonb,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, route_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_existing relay.routes;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_key IS NULL OR p_name IS NULL OR p_tree IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-59';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['route', p_key]);
        SELECT * INTO v_existing FROM relay.routes r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.key = p_key;
        IF FOUND THEN
          RETURN QUERY SELECT 'key_conflict'::text, v_existing.id, v_existing.version;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.routes (tenant_id, environment, id, key, name, tree, state, archived_at,
          version, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_key, p_name, p_tree, 'active', NULL, 1, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'route.created', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'route', p_id::text, NULL,
          p_record_digest);
        RETURN QUERY SELECT 'created'::text, p_id, 1::bigint;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.route_replace(p_key text, p_name text, p_tree jsonb,
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
        v_route relay.routes;
        v_version bigint;
      BEGIN
        IF p_name IS NULL OR p_tree IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-59';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['route', p_key]);
        SELECT * INTO v_route FROM relay.routes r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.key = p_key;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_route.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, v_route.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_route.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_route.version;
          RETURN;
        END IF;
        IF v_route.name = p_name AND v_route.tree = p_tree THEN
          RETURN QUERY SELECT 'unchanged'::text, v_route.version;
          RETURN;
        END IF;
        UPDATE relay.routes r SET name = p_name, tree = p_tree, version = r.version + 1,
            updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_route.id
          RETURNING r.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'route.replaced', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'route', v_route.id::text, NULL,
          p_record_digest);
        RETURN QUERY SELECT 'replaced'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.route_archive(p_key text, p_record_digest bytea,
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
        v_route relay.routes;
        v_version bigint;
      BEGIN
        PERFORM relay_private.lock_scope(ARRAY['route', p_key]);
        SELECT * INTO v_route FROM relay.routes r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.key = p_key;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_route.state = 'archived' THEN
          RETURN QUERY SELECT 'already_archived'::text, v_route.version;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM relay.categories c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.state = 'active'
            AND c.default_route = p_key) THEN
          RETURN QUERY SELECT 'in_use'::text, v_route.version;
          RETURN;
        END IF;
        UPDATE relay.routes r SET state = 'archived', archived_at = now(),
            version = r.version + 1, updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_route.id
          RETURNING r.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'route.archived', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'route', v_route.id::text, NULL,
          p_record_digest);
        RETURN QUERY SELECT 'archived'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.category_create(p_id uuid, p_key text, p_name text,
        p_message_class text, p_locked boolean, p_enabled boolean, p_channel_defaults jsonb,
        p_default_expires_in interval, p_frequency_limit bigint, p_frequency_window interval,
        p_frequency_fate text, p_digest_allowed boolean, p_default_route text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, category_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_existing relay.categories;
        v_locked boolean := COALESCE(p_locked, false) OR p_message_class = 'security';
        v_check text;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_key IS NULL OR p_key !~ '^[a-z][a-z0-9_]{0,63}$' OR p_name IS NULL
          OR p_message_class IS NULL OR p_enabled IS NULL OR p_channel_defaults IS NULL
          OR p_digest_allowed IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-57';
        END IF;
        v_check := relay_private.category_settings_check(p_message_class, v_locked,
          p_channel_defaults, p_default_expires_in, p_frequency_limit, p_frequency_window,
          p_frequency_fate, p_digest_allowed);
        IF v_check <> 'ok' THEN
          RETURN QUERY SELECT v_check, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        v_check := relay_private.route_check(p_default_route);
        IF v_check <> 'ok' THEN
          RETURN QUERY SELECT v_check, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['category', p_key]);
        SELECT * INTO v_existing FROM relay.categories c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key = p_key;
        IF FOUND THEN
          RETURN QUERY SELECT 'key_conflict'::text, v_existing.id, v_existing.version;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.categories (tenant_id, environment, id, key, name, message_class, locked,
          enabled, channel_defaults, default_expires_in, frequency_limit, frequency_window,
          frequency_fate, digest_allowed, default_route, builtin, state, archived_at, version,
          created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_key, p_name, p_message_class, v_locked, p_enabled,
          p_channel_defaults, p_default_expires_in, p_frequency_limit, p_frequency_window,
          p_frequency_fate, p_digest_allowed, p_default_route, false, 'active', NULL, 1, now(),
          now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'category.created',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'category',
          p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'created'::text, p_id, 1::bigint;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.category_update(p_key text, p_name text, p_locked boolean,
        p_enabled boolean, p_channel_defaults jsonb, p_default_expires_in interval,
        p_frequency_limit bigint, p_frequency_window interval, p_frequency_fate text,
        p_digest_allowed boolean, p_default_route text, p_expected_version bigint,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_category relay.categories;
        v_locked boolean;
        v_check text;
        v_action text;
        v_version bigint;
      BEGIN
        IF p_name IS NULL OR p_locked IS NULL OR p_enabled IS NULL OR p_channel_defaults IS NULL
          OR p_digest_allowed IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-57';
        END IF;
        SELECT * INTO v_category FROM relay.categories c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key = p_key
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_category.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, v_category.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_category.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_category.version;
          RETURN;
        END IF;
        v_locked := p_locked OR v_category.message_class = 'security';
        v_check := relay_private.category_settings_check(v_category.message_class, v_locked,
          p_channel_defaults, p_default_expires_in, p_frequency_limit, p_frequency_window,
          p_frequency_fate, p_digest_allowed);
        IF v_check <> 'ok' THEN
          RETURN QUERY SELECT v_check, v_category.version;
          RETURN;
        END IF;
        IF p_default_route IS DISTINCT FROM v_category.default_route THEN
          v_check := relay_private.route_check(p_default_route);
          IF v_check <> 'ok' THEN
            RETURN QUERY SELECT v_check, v_category.version;
            RETURN;
          END IF;
        END IF;
        IF v_category.name = p_name AND v_category.locked = v_locked
          AND v_category.enabled = p_enabled AND v_category.channel_defaults = p_channel_defaults
          AND v_category.default_expires_in IS NOT DISTINCT FROM p_default_expires_in
          AND v_category.frequency_limit IS NOT DISTINCT FROM p_frequency_limit
          AND v_category.frequency_window IS NOT DISTINCT FROM p_frequency_window
          AND v_category.frequency_fate IS NOT DISTINCT FROM p_frequency_fate
          AND v_category.digest_allowed = p_digest_allowed
          AND v_category.default_route IS NOT DISTINCT FROM p_default_route THEN
          RETURN QUERY SELECT 'unchanged'::text, v_category.version;
          RETURN;
        END IF;
        v_action := CASE WHEN v_category.locked <> v_locked THEN 'category.lock_changed'
          ELSE 'category.updated' END;
        UPDATE relay.categories c SET name = p_name, locked = v_locked, enabled = p_enabled,
            channel_defaults = p_channel_defaults, default_expires_in = p_default_expires_in,
            frequency_limit = p_frequency_limit, frequency_window = p_frequency_window,
            frequency_fate = p_frequency_fate, digest_allowed = p_digest_allowed,
            default_route = p_default_route, version = c.version + 1, updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_category.id
          RETURNING c.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, v_action, p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'category', v_category.id::text,
          NULL, p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_version;
      END
      $fn$
      """
    ]
  end
end
