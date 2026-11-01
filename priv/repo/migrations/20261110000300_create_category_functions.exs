defmodule Relay.Repo.Migrations.CreateCategoryFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @settings "interval, bigint, interval, text"

  @functions [
    {"relay_private.class_channel_default(text, text)", "relay_migrator",
     ~w(relay_owner relay_app relay_report)},
    {"relay_private.category_settings_check(text, boolean, jsonb, #{@settings}, boolean)",
     "relay_migrator", ~w(relay_owner)},
    {"relay_fn.category_create(uuid, text, text, text, boolean, boolean, jsonb, #{@settings}, boolean, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.category_update(text, text, boolean, boolean, jsonb, #{@settings}, boolean, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.category_archive(text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.category_subtenant_put(uuid, text, uuid, boolean, jsonb, #{@settings}, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)}
  ]

  # PC-57 (1)
  # PC-57 (2)
  # PC-57 (4)
  # PC-6
  # PC-11
  # PC-14
  # PC-50
  # OP-8
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
      CREATE FUNCTION relay_private.class_channel_default(p_class text, p_channel text)
        RETURNS boolean
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT CASE
          WHEN c.channel NOT IN ('push', 'email', 'sms', 'whatsapp', 'in_app') THEN false
          WHEN p_class = 'security' THEN c.channel <> 'whatsapp'
          WHEN p_class = 'action_required' THEN c.channel IN ('push', 'email', 'in_app')
          WHEN p_class = 'transactional' THEN c.channel <> 'whatsapp'
          WHEN p_class = 'operational' THEN c.channel IN ('push', 'email', 'in_app')
          WHEN p_class = 'social' THEN c.channel IN ('push', 'in_app')
          WHEN p_class = 'marketing' THEN c.channel = 'in_app'
          ELSE false
        END
        FROM (SELECT CASE p_channel WHEN 'web_push' THEN 'push' WHEN 'voice' THEN 'sms'
          ELSE p_channel END AS channel) c
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.category_settings_check(p_class text, p_locked boolean,
        p_channel_defaults jsonb, p_default_expires_in interval, p_frequency_limit bigint,
        p_frequency_window interval, p_frequency_fate text, p_digest_allowed boolean)
        RETURNS text
      LANGUAGE plpgsql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_entry record;
      BEGIN
        IF p_locked AND p_class NOT IN ('security', 'transactional', 'operational',
          'action_required') THEN
          RETURN 'lock_not_allowed';
        END IF;
        IF p_channel_defaults IS NOT NULL THEN
          IF jsonb_typeof(p_channel_defaults) <> 'object' THEN
            RETURN 'invalid_settings';
          END IF;
          FOR v_entry IN SELECT e.key, e.value FROM jsonb_each(p_channel_defaults) e LOOP
            IF v_entry.key NOT IN ('push', 'web_push', 'email', 'sms', 'voice', 'whatsapp', 'slack',
              'teams', 'telegram', 'discord', 'in_app', 'webhook')
              OR v_entry.value NOT IN ('"on"'::jsonb, '"off"'::jsonb) THEN
              RETURN 'invalid_settings';
            END IF;
            IF p_class = 'marketing' AND v_entry.key IN ('email', 'sms', 'voice', 'whatsapp')
              AND v_entry.value = '"on"'::jsonb THEN
              RETURN 'default_forbidden';
            END IF;
          END LOOP;
        END IF;
        IF (p_default_expires_in IS NOT NULL AND (p_class = 'security'
            OR p_default_expires_in NOT BETWEEN interval '1 minute' AND interval '30 days'))
          OR ((p_frequency_limit IS NULL) <> (p_frequency_window IS NULL))
          OR ((p_frequency_limit IS NULL) <> (p_frequency_fate IS NULL))
          OR (p_frequency_limit IS NOT NULL AND (p_class NOT IN ('marketing', 'social', 'operational')
            OR p_frequency_limit NOT BETWEEN 1 AND 10000
            OR p_frequency_window NOT BETWEEN interval '1 hour' AND interval '7 days'
            OR p_frequency_fate NOT IN ('drop', 'defer', 'digest', 'inbox_only')))
          OR (COALESCE(p_digest_allowed, false) AND p_class <> 'operational') THEN
          RETURN 'invalid_settings';
        END IF;
        RETURN 'ok';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.category_create(p_id uuid, p_key text, p_name text,
        p_message_class text, p_locked boolean, p_enabled boolean, p_channel_defaults jsonb,
        p_default_expires_in interval, p_frequency_limit bigint, p_frequency_window interval,
        p_frequency_fate text, p_digest_allowed boolean, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
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
          frequency_fate, digest_allowed, builtin, state, archived_at, version, created_at,
          updated_at)
        VALUES (v_tenant, v_env, p_id, p_key, p_name, p_message_class, v_locked, p_enabled,
          p_channel_defaults, p_default_expires_in, p_frequency_limit, p_frequency_window,
          p_frequency_fate, p_digest_allowed, false, 'active', NULL, 1, now(), now());
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
        p_digest_allowed boolean, p_expected_version bigint, p_record_digest bytea,
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
        IF v_category.name = p_name AND v_category.locked = v_locked
          AND v_category.enabled = p_enabled AND v_category.channel_defaults = p_channel_defaults
          AND v_category.default_expires_in IS NOT DISTINCT FROM p_default_expires_in
          AND v_category.frequency_limit IS NOT DISTINCT FROM p_frequency_limit
          AND v_category.frequency_window IS NOT DISTINCT FROM p_frequency_window
          AND v_category.frequency_fate IS NOT DISTINCT FROM p_frequency_fate
          AND v_category.digest_allowed = p_digest_allowed THEN
          RETURN QUERY SELECT 'unchanged'::text, v_category.version;
          RETURN;
        END IF;
        v_action := CASE WHEN v_category.locked <> v_locked THEN 'category.lock_changed'
          ELSE 'category.updated' END;
        UPDATE relay.categories c SET name = p_name, locked = v_locked, enabled = p_enabled,
            channel_defaults = p_channel_defaults, default_expires_in = p_default_expires_in,
            frequency_limit = p_frequency_limit, frequency_window = p_frequency_window,
            frequency_fate = p_frequency_fate, digest_allowed = p_digest_allowed,
            version = c.version + 1, updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_category.id
          RETURNING c.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, v_action, p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'category', v_category.id::text,
          NULL, p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.category_archive(p_key text, p_record_digest bytea,
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
        v_category relay.categories;
        v_version bigint;
      BEGIN
        SELECT * INTO v_category FROM relay.categories c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key = p_key
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_category.builtin THEN
          RETURN QUERY SELECT 'builtin'::text, v_category.version;
          RETURN;
        END IF;
        IF v_category.state = 'archived' THEN
          RETURN QUERY SELECT 'already_archived'::text, v_category.version;
          RETURN;
        END IF;
        UPDATE relay.categories c SET state = 'archived', archived_at = now(),
            version = c.version + 1, updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_category.id
          RETURNING c.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'category.archived',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'category',
          v_category.id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'archived'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.category_subtenant_put(p_id uuid, p_key text, p_subtenant_id uuid,
        p_enabled boolean, p_channel_defaults jsonb, p_default_expires_in interval,
        p_frequency_limit bigint, p_frequency_window interval, p_frequency_fate text,
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
        v_setting relay.category_subtenant_settings;
        v_check text;
        v_version bigint;
      BEGIN
        IF p_subtenant_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-57';
        END IF;
        SELECT * INTO v_category FROM relay.categories c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key = p_key;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_category.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, NULL::bigint;
          RETURN;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id) THEN
          RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        v_check := relay_private.category_settings_check(v_category.message_class, false,
          p_channel_defaults, p_default_expires_in, p_frequency_limit, p_frequency_window,
          p_frequency_fate, NULL);
        IF v_check <> 'ok' THEN
          RETURN QUERY SELECT v_check, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['category_subtenant', v_category.id::text,
          p_subtenant_id::text]);
        SELECT * INTO v_setting FROM relay.category_subtenant_settings x
          WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.category_id = v_category.id
            AND x.subtenant_id = p_subtenant_id
          FOR UPDATE;
        IF FOUND THEN
          IF v_setting.enabled IS NOT DISTINCT FROM p_enabled
            AND v_setting.channel_defaults IS NOT DISTINCT FROM p_channel_defaults
            AND v_setting.default_expires_in IS NOT DISTINCT FROM p_default_expires_in
            AND v_setting.frequency_limit IS NOT DISTINCT FROM p_frequency_limit
            AND v_setting.frequency_window IS NOT DISTINCT FROM p_frequency_window
            AND v_setting.frequency_fate IS NOT DISTINCT FROM p_frequency_fate THEN
            RETURN QUERY SELECT 'unchanged'::text, v_setting.version;
            RETURN;
          END IF;
          UPDATE relay.category_subtenant_settings x SET enabled = p_enabled,
              channel_defaults = p_channel_defaults, default_expires_in = p_default_expires_in,
              frequency_limit = p_frequency_limit, frequency_window = p_frequency_window,
              frequency_fate = p_frequency_fate, version = x.version + 1, updated_at = now()
            WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.id = v_setting.id
            RETURNING x.version INTO v_version;
          PERFORM relay_private.audit_write(v_tenant, v_env::text,
            'category_subtenant_setting.changed', p_actor_kind, p_actor_ref, p_on_behalf_of_ref,
            p_access_record_ref, 'category', v_category.id::text, p_subtenant_id::text,
            p_record_digest);
          RETURN QUERY SELECT 'updated'::text, v_version;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.category_subtenant_settings (tenant_id, environment, id, category_id,
          subtenant_id, enabled, channel_defaults, default_expires_in, frequency_limit,
          frequency_window, frequency_fate, version, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, v_category.id, p_subtenant_id, p_enabled,
          p_channel_defaults, p_default_expires_in, p_frequency_limit, p_frequency_window,
          p_frequency_fate, 1, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text,
          'category_subtenant_setting.changed', p_actor_kind, p_actor_ref, p_on_behalf_of_ref,
          p_access_record_ref, 'category', v_category.id::text, p_subtenant_id::text,
          p_record_digest);
        RETURN QUERY SELECT 'created'::text, 1::bigint;
      END
      $fn$
      """
    ]
  end
end
