defmodule Relay.Repo.Migrations.CreateRolloutAndDedupClaims do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"
  @actor "text, text, text, text"
  @tables ~w(rollout_configs dedup_claims)

  @functions [
    {"relay_fn.rollout_put(bytea[], bytea[], text[], jsonb, jsonb, bigint, bytea, #{@actor})",
     ~w(relay_app)},
    {"relay_fn.rollout_emergency_stop(text, bytea, bytea, #{@actor})", ~w(relay_app)},
    {"relay_fn.rollout_emergency_release(text, bytea, #{@actor})", ~w(relay_app)},
    {"relay_fn.dedup_claim(text, bigint)", ~w(relay_app)},
    {"relay_fn.dedup_claim_held(text)", ~w(relay_app)},
    {"relay_fn.webhook_endpoint_shadow_set(uuid, boolean, bytea, #{@actor})", ~w(relay_app)}
  ]

  # OP-53
  # OP-54
  # OP-80
  # OP-95
  # OP-52 (1)
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

    execute(
      """
      ALTER TABLE relay.webhook_endpoints ADD COLUMN IF NOT EXISTS shadow boolean NOT NULL DEFAULT false
      """
    )

    Enum.each(functions(), &execute/1)

    for {signature, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp tables do
    [
      ~S"""
      CREATE TABLE relay.rollout_configs (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        emergency_stop boolean NOT NULL,
        configured boolean NOT NULL,
        stopped_at timestamptz,
        stop_reason text
          CONSTRAINT rollout_configs_stop_reason_check
            CHECK (stop_reason IS NULL OR char_length(stop_reason) BETWEEN 1 AND 1000),
        relay_list bytea[] NOT NULL
          CONSTRAINT rollout_configs_relay_list_check CHECK (cardinality(relay_list) <= 1000),
        legacy_list bytea[] NOT NULL
          CONSTRAINT rollout_configs_legacy_list_check CHECK (cardinality(legacy_list) <= 1000),
        enabled_categories text[] NOT NULL
          CONSTRAINT rollout_configs_enabled_categories_check
            CHECK (cardinality(enabled_categories) <= 200),
        basis_points jsonb NOT NULL
          CONSTRAINT rollout_configs_basis_points_check
            CHECK (jsonb_typeof(basis_points) = 'object'
              AND pg_column_size(basis_points) <= 16384),
        steps jsonb NOT NULL
          CONSTRAINT rollout_configs_steps_check
            CHECK (jsonb_typeof(steps) = 'object' AND pg_column_size(steps) <= 32768),
        generation bigint NOT NULL
          CONSTRAINT rollout_configs_generation_check CHECK (generation >= 1),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT rollout_configs_pkey PRIMARY KEY (tenant_id, environment),
        CONSTRAINT rollout_configs_stopped_check
          CHECK (emergency_stop = (stopped_at IS NOT NULL AND stop_reason IS NOT NULL))
      )
      """,
      ~S"""
      CREATE TABLE relay.dedup_claims (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        dedup_key text NOT NULL
          CONSTRAINT dedup_claims_dedup_key_check CHECK (char_length(dedup_key) BETWEEN 1 AND 512),
        claimant text NOT NULL
          CONSTRAINT dedup_claims_claimant_check CHECK (claimant IN ('legacy')),
        claimed_at timestamptz NOT NULL,
        expires_at timestamptz NOT NULL,
        CONSTRAINT dedup_claims_pkey PRIMARY KEY (tenant_id, environment, dedup_key),
        CONSTRAINT dedup_claims_expiry_check CHECK (expires_at > claimed_at)
      )
      """
    ]
  end

  defp functions do
    [
      ~S"""
      CREATE FUNCTION relay_fn.rollout_put(p_relay_list bytea[], p_legacy_list bytea[],
        p_enabled_categories text[], p_basis_points jsonb, p_steps jsonb,
        p_expected_generation bigint, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, generation bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.rollout_configs;
        v_generation bigint;
      BEGIN
        IF p_relay_list IS NULL OR p_legacy_list IS NULL OR p_enabled_categories IS NULL
          OR p_basis_points IS NULL OR p_steps IS NULL OR p_expected_generation IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-95';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['rollout']);
        SELECT * INTO v_row FROM relay.rollout_configs c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env FOR UPDATE;
        IF COALESCE(v_row.generation, 0) <> p_expected_generation THEN
          RETURN QUERY SELECT 'version_conflict'::text, COALESCE(v_row.generation, 0);
          RETURN;
        END IF;
        IF v_row.generation IS NULL THEN
          INSERT INTO relay.rollout_configs (tenant_id, environment, emergency_stop, configured,
            stopped_at, stop_reason, relay_list, legacy_list, enabled_categories, basis_points,
            steps, generation, created_at, updated_at)
          VALUES (v_tenant, v_env, false, true, NULL, NULL, p_relay_list, p_legacy_list,
            p_enabled_categories, p_basis_points, p_steps, 1, now(), now());
          v_generation := 1;
        ELSE
          UPDATE relay.rollout_configs c SET configured = true, relay_list = p_relay_list,
              legacy_list = p_legacy_list, enabled_categories = p_enabled_categories,
              basis_points = p_basis_points, steps = p_steps, generation = c.generation + 1,
              updated_at = now()
            WHERE c.tenant_id = v_tenant AND c.environment = v_env
            RETURNING c.generation INTO v_generation;
        END IF;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'rollout.updated', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'rollout', v_env::text, NULL,
          p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_generation;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.rollout_emergency_stop(p_reason text, p_incident_digest bytea,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, generation bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.rollout_configs;
        v_generation bigint;
      BEGIN
        IF p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 1 AND 1000
          OR p_incident_digest IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-53';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['rollout']);
        SELECT * INTO v_row FROM relay.rollout_configs c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env FOR UPDATE;
        IF v_row.emergency_stop THEN
          RETURN QUERY SELECT 'already_stopped'::text, v_row.generation;
          RETURN;
        END IF;
        IF v_row.generation IS NULL THEN
          INSERT INTO relay.rollout_configs (tenant_id, environment, emergency_stop, configured,
            stopped_at, stop_reason, relay_list, legacy_list, enabled_categories, basis_points,
            steps, generation, created_at, updated_at)
          VALUES (v_tenant, v_env, true, false, now(), p_reason, ARRAY[]::bytea[], ARRAY[]::bytea[],
            ARRAY[]::text[], '{}'::jsonb, '{}'::jsonb, 1, now(), now());
          v_generation := 1;
        ELSE
          UPDATE relay.rollout_configs c SET emergency_stop = true, stopped_at = now(),
              stop_reason = p_reason, generation = c.generation + 1, updated_at = now()
            WHERE c.tenant_id = v_tenant AND c.environment = v_env
            RETURNING c.generation INTO v_generation;
        END IF;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'rollout.emergency_stopped',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'rollout',
          v_env::text, p_reason, p_record_digest);
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'incident.opened',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'rollout',
          v_env::text, p_reason, p_incident_digest);
        RETURN QUERY SELECT 'stopped'::text, v_generation;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.rollout_emergency_release(p_reason text, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, generation bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.rollout_configs;
        v_generation bigint;
      BEGIN
        IF p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 1 AND 1000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-53';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['rollout']);
        SELECT * INTO v_row FROM relay.rollout_configs c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env FOR UPDATE;
        IF v_row.generation IS NULL OR NOT v_row.emergency_stop THEN
          RETURN QUERY SELECT 'not_stopped'::text, COALESCE(v_row.generation, 0);
          RETURN;
        END IF;
        UPDATE relay.rollout_configs c SET emergency_stop = false, stopped_at = NULL,
            stop_reason = NULL, generation = c.generation + 1, updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env
          RETURNING c.generation INTO v_generation;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'rollout.emergency_released',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'rollout',
          v_env::text, p_reason, p_record_digest);
        RETURN QUERY SELECT 'released'::text, v_generation;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.dedup_claim(p_dedup_key text, p_ttl_seconds bigint)
        RETURNS TABLE (result text, claimed_by text, expires_at timestamptz)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_claim relay.dedup_claims;
        v_expires timestamptz;
      BEGIN
        IF p_dedup_key IS NULL OR char_length(p_dedup_key) NOT BETWEEN 1 AND 512
          OR p_ttl_seconds IS NULL OR p_ttl_seconds < 1 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-54';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['dedup_claim', p_dedup_key]);
        SELECT * INTO v_claim FROM relay.dedup_claims c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.dedup_key = p_dedup_key;
        IF FOUND AND v_claim.expires_at > now() THEN
          RETURN QUERY SELECT 'duplicate'::text, v_claim.claimant, v_claim.expires_at;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM relay.notifications n
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.dedup_key = p_dedup_key) THEN
          RETURN QUERY SELECT 'duplicate'::text, 'relay'::text, NULL::timestamptz;
          RETURN;
        END IF;
        v_expires := now() + make_interval(secs => p_ttl_seconds);
        INSERT INTO relay.dedup_claims AS c (tenant_id, environment, dedup_key, claimant,
          claimed_at, expires_at)
        VALUES (v_tenant, v_env, p_dedup_key, 'legacy', now(), v_expires)
        ON CONFLICT (tenant_id, environment, dedup_key)
          DO UPDATE SET claimant = 'legacy', claimed_at = now(), expires_at = v_expires;
        RETURN QUERY SELECT 'claimed'::text, 'legacy'::text, v_expires;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.dedup_claim_held(p_dedup_key text) RETURNS boolean
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        IF p_dedup_key IS NULL THEN
          RETURN false;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['dedup_claim', p_dedup_key]);
        RETURN EXISTS (SELECT 1 FROM relay.dedup_claims c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.dedup_key = p_dedup_key
            AND c.expires_at > now());
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.webhook_endpoint_shadow_set(p_endpoint_id uuid, p_shadow boolean,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.webhook_endpoints;
      BEGIN
        IF p_shadow IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-94';
        END IF;
        SELECT * INTO v_row FROM relay.webhook_endpoints e
          WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_id
          FOR UPDATE;
        IF NOT FOUND OR v_row.use_kind <> 'relay_events' THEN
          RETURN 'not_found';
        END IF;
        IF v_row.state = 'archived' THEN
          RETURN 'archived';
        END IF;
        IF v_row.shadow = p_shadow THEN
          RETURN 'unchanged';
        END IF;
        UPDATE relay.webhook_endpoints e SET shadow = p_shadow, version = e.version + 1,
            updated_at = now()
          WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_endpoint_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'webhook_endpoint.updated',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'webhook_endpoint',
          p_endpoint_id::text, CASE WHEN p_shadow THEN 'shadow' ELSE 'live' END,
          p_record_digest);
        RETURN 'set';
      END
      $fn$
      """
    ]
  end
end
