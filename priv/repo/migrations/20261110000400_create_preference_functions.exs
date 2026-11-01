defmodule Relay.Repo.Migrations.CreatePreferenceFunctions do
  use Ecto.Migration

  @functions [
    {"relay_private.time_ranges_valid(jsonb)", "relay_migrator", ~w(relay_owner)},
    {"relay_private.category_open_channels(uuid, uuid, uuid)", "relay_migrator", ~w(relay_owner)},
    {"relay_fn.preference_set(uuid, uuid, text, text, text, text, text, text)", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.preference_profile_put(uuid, jsonb, jsonb, timestamptz, boolean, jsonb, text, bigint)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.preference_cells(uuid)", "relay_owner", ~w(relay_app relay_report)}
  ]

  # PC-57 (5)
  # PC-6
  # PC-12
  # PC-13
  # PC-14
  # PC-15
  # PC-16
  # PC-17
  # PC-45
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
      CREATE FUNCTION relay_private.time_ranges_valid(p_ranges jsonb) RETURNS boolean
      LANGUAGE sql IMMUTABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT CASE WHEN jsonb_typeof(p_ranges) IS DISTINCT FROM 'array' THEN false
          ELSE jsonb_array_length(p_ranges) <= 28 AND NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(p_ranges) r
            WHERE CASE WHEN jsonb_typeof(r) <> 'object' THEN true
              ELSE (SELECT count(*) FROM jsonb_object_keys(r)) <> 3
                OR NOT (r ? 'day' AND r ? 'start' AND r ? 'end')
                OR jsonb_typeof(r -> 'day') <> 'string'
                OR jsonb_typeof(r -> 'start') <> 'string'
                OR jsonb_typeof(r -> 'end') <> 'string'
                OR (r ->> 'day') NOT IN ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
                OR (r ->> 'start') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
                OR (r ->> 'end') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
                OR (r ->> 'start') = (r ->> 'end') END) END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.category_open_channels(p_tenant_id uuid,
        p_category_id uuid, p_recipient_id uuid) RETURNS bigint
      LANGUAGE sql STABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT count(*)
        FROM relay.categories c
        CROSS JOIN LATERAL (
          SELECT u.channel FROM unnest(ARRAY['push', 'email', 'sms', 'whatsapp', 'in_app']) u(channel)
          UNION
          SELECT d.key FROM jsonb_each_text(c.channel_defaults) d) ch
        LEFT JOIN relay.preferences cc ON cc.tenant_id = c.tenant_id
          AND cc.environment = c.environment AND cc.recipient_id = p_recipient_id
          AND cc.level = 'category_channel' AND cc.key = c.key AND cc.channel = ch.channel
        WHERE c.tenant_id = p_tenant_id AND c.environment = relay_private.ctx_environment()
          AND c.id = p_category_id
          AND NOT EXISTS (SELECT 1 FROM relay.preferences g
            WHERE g.tenant_id = c.tenant_id AND g.environment = c.environment
              AND g.recipient_id = p_recipient_id AND g.level = 'channel'
              AND g.channel = ch.channel AND g.value = 'opt_out')
          AND CASE COALESCE(cc.value, 'unset')
            WHEN 'opt_in' THEN true
            WHEN 'opt_out' THEN false
            ELSE COALESCE((c.channel_defaults ->> ch.channel) = 'on',
              relay_private.class_channel_default(c.message_class, ch.channel))
          END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.preference_set(p_id uuid, p_recipient_id uuid, p_level text,
        p_key text, p_channel text, p_value text, p_writer text, p_actor_ref text)
        RETURNS TABLE (result text, preference_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_current relay.preferences;
        v_category relay.categories;
        v_id uuid;
        v_version bigint;
        v_old text;
      BEGIN
        IF p_level IS NULL OR p_level NOT IN ('category_channel', 'channel', 'workflow', 'scope_key')
          OR p_value IS NULL OR p_value NOT IN ('opt_in', 'opt_out', 'unset')
          OR p_writer IS NULL OR p_writer NOT IN ('subscriber', 'tenant', 'access', 'unsubscribe')
          OR (p_level = 'category_channel' AND (p_key IS NULL OR p_channel IS NULL))
          OR (p_level = 'channel' AND (p_key IS NOT NULL OR p_channel IS NULL))
          OR (p_level IN ('workflow', 'scope_key') AND p_key IS NULL)
          OR char_length(p_key) > 256 OR char_length(p_actor_ref) > 256 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-57';
        END IF;
        IF p_writer IN ('tenant', 'unsubscribe') AND p_value <> 'opt_out' THEN
          RETURN QUERY SELECT 'direction_forbidden'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        PERFORM 1 FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
            AND r.state = 'active'
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_level = 'category_channel' THEN
          SELECT * INTO v_category FROM relay.categories c
            WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key = p_key;
          IF NOT FOUND THEN
            RETURN QUERY SELECT 'category_not_found'::text, NULL::uuid, NULL::bigint;
            RETURN;
          END IF;
        END IF;
        SELECT * INTO v_current FROM relay.preferences p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env
            AND p.recipient_id = p_recipient_id AND p.level = p_level
            AND p.key IS NOT DISTINCT FROM p_key AND p.channel IS NOT DISTINCT FROM p_channel
          FOR UPDATE;
        IF FOUND AND v_current.value = p_value THEN
          RETURN QUERY SELECT 'unchanged'::text, v_current.id, v_current.version;
          RETURN;
        END IF;
        BEGIN
          IF v_current.id IS NOT NULL THEN
            v_old := v_current.value;
            v_id := v_current.id;
            UPDATE relay.preferences p SET value = p_value, updated_by = p_writer,
                version = p.version + 1, updated_at = now()
              WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.id = v_current.id
              RETURNING p.version INTO v_version;
          ELSE
            PERFORM relay_private.assert_new_id(p_id);
            v_id := p_id;
            v_version := 1;
            INSERT INTO relay.preferences (tenant_id, environment, id, recipient_id, level, key,
              channel, value, updated_by, version, created_at, updated_at)
            VALUES (v_tenant, v_env, p_id, p_recipient_id, p_level, p_key, p_channel, p_value,
              p_writer, 1, now(), now());
          END IF;
          IF p_value = 'opt_out' AND p_level IN ('category_channel', 'channel') AND EXISTS (
            SELECT 1 FROM relay.categories c
            WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.locked
              AND c.state = 'active'
              AND (p_level = 'channel' OR c.id = v_category.id)
              AND relay_private.category_open_channels(v_tenant, c.id, p_recipient_id) = 0) THEN
            RAISE EXCEPTION 'last_channel' USING ERRCODE = 'RL001', HINT = 'PC-6';
          END IF;
        EXCEPTION WHEN SQLSTATE 'RL001' THEN
          RETURN QUERY SELECT 'last_channel'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END;
        INSERT INTO relay.preference_changes (tenant_id, environment, id, preference_id,
          recipient_id, old_value, new_value, writer, actor_ref, created_at)
        VALUES (v_tenant, v_env, uuidv7(), v_id, p_recipient_id, v_old, p_value, p_writer,
          p_actor_ref, now());
        RETURN QUERY SELECT 'set'::text, v_id, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.preference_profile_put(p_recipient_id uuid, p_quiet_hours jsonb,
        p_schedule jsonb, p_dnd_until timestamptz, p_quiet_hours_email boolean, p_digest jsonb,
        p_writer text, p_expected_version bigint)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_profile relay.preference_profiles;
        v_version bigint;
      BEGIN
        IF p_writer IS NULL OR p_quiet_hours IS NULL OR p_schedule IS NULL
          OR p_quiet_hours_email IS NULL OR p_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-57';
        END IF;
        IF p_writer NOT IN ('subscriber', 'access') THEN
          RETURN QUERY SELECT 'writer_forbidden'::text, NULL::bigint;
          RETURN;
        END IF;
        IF NOT relay_private.time_ranges_valid(p_quiet_hours)
          OR NOT relay_private.time_ranges_valid(p_schedule)
          OR jsonb_typeof(p_digest) <> 'object' THEN
          RETURN QUERY SELECT 'invalid_profile'::text, NULL::bigint;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_each(p_digest) d
          WHERE d.key !~ '^[a-z][a-z0-9_]{0,63}$'
            OR d.value NOT IN ('"instant"'::jsonb, '"digest"'::jsonb)) THEN
          RETURN QUERY SELECT 'invalid_profile'::text, NULL::bigint;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_each(p_digest) d
          WHERE NOT EXISTS (SELECT 1 FROM relay.categories c
            WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.key = d.key
              AND (c.message_class = 'social'
                OR (c.message_class = 'operational' AND c.digest_allowed)))) THEN
          RETURN QUERY SELECT 'digest_not_allowed'::text, NULL::bigint;
          RETURN;
        END IF;
        PERFORM 1 FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
            AND r.state = 'active'
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'recipient_not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT * INTO v_profile FROM relay.preference_profiles p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env
            AND p.recipient_id = p_recipient_id
          FOR UPDATE;
        IF NOT FOUND THEN
          INSERT INTO relay.preference_profiles (tenant_id, environment, recipient_id,
            quiet_hours, schedule, dnd_until, quiet_hours_email, digest, updated_by, version,
            created_at, updated_at)
          VALUES (v_tenant, v_env, p_recipient_id, p_quiet_hours, p_schedule, p_dnd_until,
            p_quiet_hours_email, p_digest, p_writer, 1, now(), now());
          RETURN QUERY SELECT 'created'::text, 1::bigint;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_profile.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_profile.version;
          RETURN;
        END IF;
        IF v_profile.quiet_hours = p_quiet_hours AND v_profile.schedule = p_schedule
          AND v_profile.dnd_until IS NOT DISTINCT FROM p_dnd_until
          AND v_profile.quiet_hours_email = p_quiet_hours_email AND v_profile.digest = p_digest THEN
          RETURN QUERY SELECT 'unchanged'::text, v_profile.version;
          RETURN;
        END IF;
        UPDATE relay.preference_profiles p SET quiet_hours = p_quiet_hours, schedule = p_schedule,
            dnd_until = p_dnd_until, quiet_hours_email = p_quiet_hours_email, digest = p_digest,
            updated_by = p_writer, version = p.version + 1, updated_at = now()
          WHERE p.tenant_id = v_tenant AND p.environment = v_env
            AND p.recipient_id = p_recipient_id
          RETURNING p.version INTO v_version;
        RETURN QUERY SELECT 'updated'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.preference_cells(p_recipient_id uuid)
        RETURNS TABLE (category_key text, message_class text, locked boolean, channel text,
          value text, effective boolean, source text)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT x.key, x.message_class::text, x.locked, x.channel, x.value,
          x.effective, CASE
            WHEN NOT x.enabled THEN 'tenant'
            WHEN x.writer = 'tenant' THEN 'tenant'
            WHEN x.value <> 'unset' OR x.channel_off THEN 'user'
            WHEN x.locked AND x.effective THEN 'locked'
            WHEN x.category_default IS NOT NULL THEN 'category_default'
            ELSE 'class_default'
          END
        FROM (
          SELECT c.key, c.message_class, c.locked, c.enabled, ch.channel,
            COALESCE(cc.value, 'unset') AS value, cc.updated_by AS writer,
            (c.channel_defaults ->> ch.channel) AS category_default,
            EXISTS (SELECT 1 FROM relay.preferences g
              WHERE g.tenant_id = c.tenant_id AND g.environment = c.environment
                AND g.recipient_id = p_recipient_id AND g.level = 'channel'
                AND g.channel = ch.channel AND g.value = 'opt_out') AS channel_off,
            c.enabled AND NOT EXISTS (SELECT 1 FROM relay.preferences g
              WHERE g.tenant_id = c.tenant_id AND g.environment = c.environment
                AND g.recipient_id = p_recipient_id AND g.level = 'channel'
                AND g.channel = ch.channel AND g.value = 'opt_out')
            AND CASE COALESCE(cc.value, 'unset')
              WHEN 'opt_in' THEN true
              WHEN 'opt_out' THEN false
              ELSE COALESCE((c.channel_defaults ->> ch.channel) = 'on',
                relay_private.class_channel_default(c.message_class, ch.channel))
            END AS effective
          FROM relay.categories c
          CROSS JOIN LATERAL (
            SELECT u.channel FROM unnest(ARRAY['push', 'email', 'sms', 'whatsapp', 'in_app']) u(channel)
            UNION
            SELECT d.key FROM jsonb_each_text(c.channel_defaults) d) ch
          LEFT JOIN relay.preferences cc ON cc.tenant_id = c.tenant_id
            AND cc.environment = c.environment AND cc.recipient_id = p_recipient_id
            AND cc.level = 'category_channel' AND cc.key = c.key AND cc.channel = ch.channel
          WHERE c.tenant_id = relay_private.ctx_tenant_id()
            AND c.environment = relay_private.ctx_environment()
            AND c.state = 'active' AND c.message_class <> 'system'
        ) x
        ORDER BY x.key, x.channel
      $fn$
      """
    ]
  end
end
