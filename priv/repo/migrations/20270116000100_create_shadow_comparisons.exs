defmodule Relay.Repo.Migrations.CreateShadowComparisons do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"
  @actor "text, text, text, text"
  @tables ~w(shadow_keys shadow_comparisons shadow_differences)
  @fields "ARRAY['recipients', 'decision', 'consent', 'timing', 'dedup_key', 'schedule', 'content', 'provider', 'sender']::text[]"

  @functions [
    {"relay_fn.shadow_key_create(uuid, date, bytea, uuid)", ~w(relay_app)},
    {"relay_fn.shadow_key_destroy(uuid, bytea, #{@actor})", ~w(relay_app)},
    {"relay_fn.shadow_side_record(uuid, text, text, uuid, uuid, text, text, text, bytea)",
     ~w(relay_app)},
    {"relay_fn.shadow_compare_set(uuid, text, boolean, boolean, boolean, text[], boolean)",
     ~w(relay_app)},
    {"relay_fn.shadow_difference_create(uuid, text, text, text, text, text, text, timestamptz, bytea, #{@actor})",
     ~w(relay_app)},
    {"relay_fn.shadow_difference_renew(uuid, timestamptz, text, bytea, #{@actor})",
     ~w(relay_app)}
  ]

  # OP-52
  # OP-79
  # OP-94
  # TN-12
  # TN-13
  def up do
    Enum.each(tables(), &execute/1)

    for table <- @tables do
      execute("""
      CREATE TRIGGER #{table}_no_delete BEFORE DELETE ON relay.#{table}
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """)

      execute("""
      CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON relay.#{table}
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """)

      execute("ALTER TABLE relay.#{table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE relay.#{table} FORCE ROW LEVEL SECURITY")

      execute(
        "CREATE POLICY #{table}_scope ON relay.#{table} USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
      )

      execute("GRANT SELECT, INSERT, UPDATE ON relay.#{table} TO relay_owner")

      execute(
        "GRANT SELECT ON relay.#{table} TO relay_app, relay_maint, relay_archive, relay_report"
      )
    end

    Enum.each(functions(), &execute/1)

    for {signature, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end

    execute(shadow_keys_due())
    execute("REVOKE ALL ON FUNCTION relay_ops.shadow_keys_due(integer) FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION relay_ops.shadow_keys_due(integer) TO relay_worker")
  end

  def down, do: :ok

  defp tables do
    [
      ~S"""
      CREATE TABLE relay.shadow_keys (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        key_day date NOT NULL,
        wrapped_dek bytea,
        wrapping_key_id uuid NOT NULL,
        state text NOT NULL
          CONSTRAINT shadow_keys_state_check CHECK (state IN ('active', 'destroyed')),
        destroyed_at timestamptz,
        created_at timestamptz NOT NULL,
        CONSTRAINT shadow_keys_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT shadow_keys_key_day_key UNIQUE (tenant_id, environment, key_day),
        CONSTRAINT shadow_keys_destroyed_check
          CHECK ((state = 'destroyed') = (wrapped_dek IS NULL AND destroyed_at IS NOT NULL)),
        CONSTRAINT shadow_keys_wrapping_key_id_fkey
          FOREIGN KEY (tenant_id, environment, wrapping_key_id)
          REFERENCES relay.tenant_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE TABLE relay.shadow_comparisons (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        correlation_id text NOT NULL
          CONSTRAINT shadow_comparisons_correlation_id_check
            CHECK (correlation_id ~ '^[\\x20-\\x7E]{1,128}$'),
        channel relay.channel NOT NULL,
        recipient_id uuid NOT NULL,
        key_id uuid NOT NULL,
        template_key text
          CONSTRAINT shadow_comparisons_template_key_check
            CHECK (template_key IS NULL OR char_length(template_key) BETWEEN 1 AND 128),
        locale text
          CONSTRAINT shadow_comparisons_locale_check
            CHECK (locale IS NULL OR char_length(locale) BETWEEN 2 AND 35),
        legacy_ct bytea,
        legacy_at timestamptz,
        relay_ct bytea,
        relay_at timestamptz,
        delivery_ct bytea,
        delivery_at timestamptz,
        state text NOT NULL
          CONSTRAINT shadow_comparisons_state_check
            CHECK (state IN ('pending', 'matched', 'differs')),
        decision_match boolean,
        content_match boolean,
        routing_match boolean,
        differing text[] NOT NULL
          CONSTRAINT shadow_comparisons_differing_check
            CHECK (cardinality(differing) <= 9 AND differing <@ #{@fields}),
        unpermitted boolean NOT NULL,
        compared_at timestamptz,
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT shadow_comparisons_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT shadow_comparisons_request_key
          UNIQUE (tenant_id, environment, correlation_id, channel, recipient_id),
        CONSTRAINT shadow_comparisons_legacy_check CHECK ((legacy_ct IS NULL) = (legacy_at IS NULL)),
        CONSTRAINT shadow_comparisons_relay_check CHECK ((relay_ct IS NULL) = (relay_at IS NULL)),
        CONSTRAINT shadow_comparisons_delivery_check
          CHECK ((delivery_ct IS NULL) = (delivery_at IS NULL)),
        CONSTRAINT shadow_comparisons_recipient_id_fkey
          FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT shadow_comparisons_key_id_fkey
          FOREIGN KEY (tenant_id, environment, key_id)
          REFERENCES relay.shadow_keys (tenant_id, environment, id)
          ON DELETE RESTRICT ON UPDATE RESTRICT
      )
      """,
      """
      CREATE INDEX shadow_comparisons_created_at_index
        ON relay.shadow_comparisons (tenant_id, environment, created_at)
      """,
      """
      CREATE TABLE relay.shadow_differences (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        layer text NOT NULL
          CONSTRAINT shadow_differences_layer_check
            CHECK (layer IN ('decision', 'content', 'routing')),
        field text
          CONSTRAINT shadow_differences_field_check
            CHECK (field IS NULL OR field = ANY (#{@fields})),
        template_key text
          CONSTRAINT shadow_differences_template_key_check
            CHECK (template_key IS NULL OR char_length(template_key) BETWEEN 1 AND 128),
        channel relay.channel,
        owner text NOT NULL
          CONSTRAINT shadow_differences_owner_check CHECK (char_length(owner) BETWEEN 1 AND 200),
        reason text NOT NULL
          CONSTRAINT shadow_differences_reason_check CHECK (char_length(reason) BETWEEN 1 AND 1000),
        expires_at timestamptz NOT NULL,
        renewals bigint NOT NULL
          CONSTRAINT shadow_differences_renewals_check CHECK (renewals >= 0),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT shadow_differences_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT shadow_differences_expiry_check CHECK (expires_at > created_at)
      )
      """
    ]
  end

  defp functions do
    [
      ~S"""
      CREATE FUNCTION relay_fn.shadow_key_create(p_id uuid, p_key_day date, p_wrapped_dek bytea,
        p_wrapping_key_id uuid)
        RETURNS TABLE (result text, shadow_key_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_existing uuid;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_key_day IS NULL OR p_wrapped_dek IS NULL OR p_wrapping_key_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-94';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['shadow_key', p_key_day::text]);
        SELECT k.id INTO v_existing FROM relay.shadow_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.key_day = p_key_day;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_existing;
          RETURN;
        END IF;
        INSERT INTO relay.shadow_keys (tenant_id, environment, id, key_day, wrapped_dek,
          wrapping_key_id, state, destroyed_at, created_at)
        VALUES (v_tenant, v_env, p_id, p_key_day, p_wrapped_dek, p_wrapping_key_id, 'active', NULL,
          now());
        RETURN QUERY SELECT 'created'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.shadow_key_destroy(p_key_id uuid, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_key relay.shadow_keys;
      BEGIN
        SELECT * INTO v_key FROM relay.shadow_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_key_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_key.state = 'destroyed' THEN
          RETURN 'already_destroyed';
        END IF;
        IF v_key.key_day >= current_date THEN
          RETURN 'not_allowed';
        END IF;
        UPDATE relay.shadow_keys k SET wrapped_dek = NULL, state = 'destroyed', destroyed_at = now()
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_key_id;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'shadow_key.destroyed', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'shadow_key', p_key_id::text,
          'retention_end', p_record_digest);
        RETURN 'destroyed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.shadow_side_record(p_id uuid, p_correlation_id text,
        p_channel text, p_recipient_id uuid, p_key_id uuid, p_side text, p_template_key text,
        p_locale text, p_ct bytea)
        RETURNS TABLE (result text, comparison_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.shadow_comparisons;
      BEGIN
        IF p_correlation_id IS NULL OR p_channel IS NULL OR p_recipient_id IS NULL
          OR p_key_id IS NULL OR p_ct IS NULL
          OR p_side IS NULL OR p_side NOT IN ('legacy', 'relay', 'delivery') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-94';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['shadow_comparison', p_correlation_id, p_channel,
          p_recipient_id::text]);
        SELECT * INTO v_row FROM relay.shadow_comparisons c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env
            AND c.correlation_id = p_correlation_id AND c.channel = p_channel
            AND c.recipient_id = p_recipient_id;
        IF NOT FOUND THEN
          PERFORM relay_private.assert_new_id(p_id);
          INSERT INTO relay.shadow_comparisons (tenant_id, environment, id, correlation_id, channel,
            recipient_id, key_id, template_key, locale, legacy_ct, legacy_at, relay_ct, relay_at,
            delivery_ct, delivery_at, state, decision_match, content_match, routing_match,
            differing, unpermitted, compared_at, created_at, updated_at)
          VALUES (v_tenant, v_env, p_id, p_correlation_id, p_channel, p_recipient_id, p_key_id,
            p_template_key, p_locale,
            CASE WHEN p_side = 'legacy' THEN p_ct END,
            CASE WHEN p_side = 'legacy' THEN now() END,
            CASE WHEN p_side = 'relay' THEN p_ct END,
            CASE WHEN p_side = 'relay' THEN now() END,
            CASE WHEN p_side = 'delivery' THEN p_ct END,
            CASE WHEN p_side = 'delivery' THEN now() END,
            'pending', NULL, NULL, NULL, ARRAY[]::text[], false, NULL, now(), now());
          RETURN QUERY SELECT 'recorded'::text, p_id;
          RETURN;
        END IF;
        IF v_row.key_id <> p_key_id THEN
          RETURN QUERY SELECT 'key_mismatch'::text, v_row.id;
          RETURN;
        END IF;
        IF p_side = 'legacy' AND v_row.legacy_ct IS NOT NULL THEN
          RETURN QUERY SELECT 'unchanged'::text, v_row.id;
          RETURN;
        END IF;
        UPDATE relay.shadow_comparisons c SET
            legacy_ct = CASE WHEN p_side = 'legacy' THEN p_ct ELSE c.legacy_ct END,
            legacy_at = CASE WHEN p_side = 'legacy' THEN now() ELSE c.legacy_at END,
            relay_ct = CASE WHEN p_side = 'relay' THEN p_ct ELSE c.relay_ct END,
            relay_at = CASE WHEN p_side = 'relay' THEN now() ELSE c.relay_at END,
            delivery_ct = CASE WHEN p_side = 'delivery' THEN p_ct ELSE c.delivery_ct END,
            delivery_at = CASE WHEN p_side = 'delivery' THEN now() ELSE c.delivery_at END,
            template_key = COALESCE(c.template_key, p_template_key),
            locale = COALESCE(c.locale, p_locale),
            updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_row.id;
        RETURN QUERY SELECT 'recorded'::text, v_row.id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.shadow_compare_set(p_comparison_id uuid, p_state text,
        p_decision_match boolean, p_content_match boolean, p_routing_match boolean,
        p_differing text[], p_unpermitted boolean)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        IF p_state IS NULL OR p_state NOT IN ('pending', 'matched', 'differs')
          OR p_differing IS NULL OR p_unpermitted IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-94';
        END IF;
        UPDATE relay.shadow_comparisons c SET state = p_state, decision_match = p_decision_match,
            content_match = p_content_match, routing_match = p_routing_match,
            differing = p_differing, unpermitted = p_unpermitted, compared_at = now(),
            updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_comparison_id;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        RETURN 'set';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.shadow_difference_create(p_id uuid, p_layer text, p_field text,
        p_template_key text, p_channel text, p_owner text, p_reason text,
        p_expires_at timestamptz, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        IF p_layer IS NULL OR p_owner IS NULL OR p_reason IS NULL OR p_expires_at IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-79';
        END IF;
        IF EXISTS (SELECT 1 FROM relay.shadow_differences d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_id) THEN
          RETURN 'exists';
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        IF p_expires_at <= now() OR p_expires_at > now() + interval '30 days' THEN
          RETURN 'invalid_expiry';
        END IF;
        INSERT INTO relay.shadow_differences (tenant_id, environment, id, layer, field,
          template_key, channel, owner, reason, expires_at, renewals, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_layer, p_field, p_template_key, p_channel, p_owner,
          p_reason, p_expires_at, 0, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env, 'shadow_difference.created',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'shadow_difference',
          p_id::text, p_reason, p_record_digest);
        RETURN 'created';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.shadow_difference_renew(p_id uuid, p_expires_at timestamptz,
        p_reason text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        IF p_expires_at IS NULL OR p_reason IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-79';
        END IF;
        PERFORM 1 FROM relay.shadow_differences d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF p_expires_at <= now() OR p_expires_at > now() + interval '30 days' THEN
          RETURN 'invalid_expiry';
        END IF;
        UPDATE relay.shadow_differences d SET expires_at = p_expires_at, reason = p_reason,
            renewals = d.renewals + 1, updated_at = now()
          WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'shadow_difference.renewed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'shadow_difference',
          p_id::text, p_reason, p_record_digest);
        RETURN 'renewed';
      END
      $fn$
      """
    ]
  end

  defp shadow_keys_due do
    ~S"""
    CREATE FUNCTION relay_ops.shadow_keys_due(p_limit integer)
      RETURNS TABLE (tenant_id uuid, environment text, key_id uuid, key_day date)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      WITH periods AS (
        SELECT p ->> 'region' AS region, p ->> 'sector' AS sector, (p ->> 'days')::integer AS days
        FROM relay.dataset_active a
        JOIN relay.dataset_versions v
          ON v.tenant_id = a.tenant_id AND v.environment = a.environment AND v.id = a.version_id
        CROSS JOIN LATERAL jsonb_array_elements(v.content -> 'periods') AS p
        WHERE a.tenant_id = relay_private.installation_tenant_id() AND a.environment = 'live'
          AND a.dataset_name = 'retention_periods' AND p ->> 'retention_class' = 'shadow'
      )
      SELECT k.tenant_id, k.environment::text, k.id, k.key_day
      FROM relay.shadow_keys k
      JOIN relay.tenants t ON t.id = k.tenant_id
      LEFT JOIN periods p ON p.region = t.region AND p.sector = t.sector
      WHERE k.state = 'active'
        AND k.key_day + LEAST(COALESCE(p.days, 14), 14) <= current_date
      ORDER BY k.key_day, k.tenant_id, k.environment, k.id
      LIMIT GREATEST(COALESCE(p_limit, 100), 1)
    $fn$
    """
  end
end
