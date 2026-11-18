defmodule Relay.Repo.Migrations.CreateFaultInjections do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"
  @clear_columns "ARRAY['status', 'cleared_at', 'cleared_by_ref', 'clear_reason']"
  @actor "text, text, text, text"

  @functions [
    {"relay_fn.fault_injection_engage(uuid, text, uuid, text, text, text, text, integer, integer, text, integer, bytea, #{@actor})",
     ~w(relay_app)},
    {"relay_fn.fault_injection_clear(uuid, text, bytea, #{@actor})", ~w(relay_app)},
    {"relay_fn.fault_injection_list(boolean, integer)", ~w(relay_app relay_report)}
  ]

  # OP-92
  # OP-44
  # OP-78
  # TN-12
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.fault_injections (
        tenant_id uuid NOT NULL,
        environment relay.environment NOT NULL,
        id uuid NOT NULL,
        scope_kind text NOT NULL
          CONSTRAINT fault_injections_scope_kind_check
            CHECK (scope_kind IN ('installation', 'tenant')),
        scope_tenant_id uuid,
        target_environment relay.environment NOT NULL,
        channel relay.channel,
        provider text
          CONSTRAINT fault_injections_provider_check
            CHECK (provider ~ '^[a-z][a-z0-9_]{0,63}$'),
        kind text NOT NULL
          CONSTRAINT fault_injections_kind_check CHECK (kind IN ('provider_auth_error',
            'rate_limited_429', 'concurrency_exhausted', 'bounce_spike', 'template_paused',
            'delayed_delivery_report', 'iys_pull_stalled', 'added_latency')),
        rate_percent bigint NOT NULL
          CONSTRAINT fault_injections_rate_percent_check CHECK (rate_percent BETWEEN 0 AND 100),
        delay_ms bigint
          CONSTRAINT fault_injections_delay_ms_range_check CHECK (delay_ms BETWEEN 1 AND 3600000),
        reason text NOT NULL
          CONSTRAINT fault_injections_reason_check
            CHECK (char_length(btrim(reason)) BETWEEN 1 AND 2000),
        created_by_ref text NOT NULL
          CONSTRAINT fault_injections_created_by_ref_check CHECK (char_length(created_by_ref) <= 256),
        expires_at timestamptz NOT NULL,
        status text NOT NULL
          CONSTRAINT fault_injections_status_check CHECK (status IN ('active', 'cleared')),
        cleared_at timestamptz,
        cleared_by_ref text,
        clear_reason text,
        created_at timestamptz NOT NULL,
        CONSTRAINT fault_injections_pkey PRIMARY KEY (tenant_id, environment, id),
        CONSTRAINT fault_injections_scope_tenant_check
          CHECK ((scope_kind = 'tenant') = (scope_tenant_id IS NOT NULL)),
        CONSTRAINT fault_injections_delay_ms_check
          CHECK ((kind IN ('added_latency', 'delayed_delivery_report')) = (delay_ms IS NOT NULL)),
        CONSTRAINT fault_injections_latency_check
          CHECK (kind <> 'added_latency' OR delay_ms <= 10000),
        CONSTRAINT fault_injections_iys_check
          CHECK (kind <> 'iys_pull_stalled' OR (channel IS NULL AND provider IS NULL)),
        CONSTRAINT fault_injections_expires_at_check
          CHECK (expires_at > created_at AND expires_at <= created_at + interval '1 hour'),
        CONSTRAINT fault_injections_cleared_at_check
          CHECK ((status = 'cleared') = (cleared_at IS NOT NULL)),
        CONSTRAINT fault_injections_clear_check
          CHECK (status = 'active' OR (cleared_by_ref IS NOT NULL
            AND char_length(btrim(clear_reason)) BETWEEN 1 AND 2000))
      )
      """,
      """
      CREATE INDEX fault_injections_active_index ON relay.fault_injections (tenant_id, environment)
        WHERE status = 'active'
      """,
      """
      CREATE FUNCTION relay_private.fault_injections_guard() RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF OLD.status = 'active' AND NEW.status = 'cleared'
          AND (to_jsonb(NEW) - #{@clear_columns}) = (to_jsonb(OLD) - #{@clear_columns}) THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = format('%s on %I.%I is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME),
                HINT = 'OP-92';
      END
      $fn$
      """,
      "REVOKE ALL ON FUNCTION relay_private.fault_injections_guard() FROM PUBLIC",
      """
      CREATE TRIGGER fault_injections_guard BEFORE UPDATE ON relay.fault_injections
        FOR EACH ROW EXECUTE FUNCTION relay_private.fault_injections_guard()
      """,
      """
      CREATE TRIGGER fault_injections_no_delete BEFORE DELETE ON relay.fault_injections
        FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      """
      CREATE TRIGGER fault_injections_no_truncate BEFORE TRUNCATE ON relay.fault_injections
        FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
      """,
      "ALTER TABLE relay.fault_injections ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE relay.fault_injections FORCE ROW LEVEL SECURITY",
      "CREATE POLICY fault_injections_scope ON relay.fault_injections USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})",
      "GRANT SELECT, INSERT, UPDATE ON relay.fault_injections TO relay_owner",
      "GRANT SELECT ON relay.fault_injections TO relay_app, relay_maint, relay_archive, relay_report",
      ~S"""
      CREATE FUNCTION relay_fn.fault_injection_engage(p_id uuid, p_scope_kind text,
        p_scope_tenant_id uuid, p_target_environment text, p_channel text, p_provider text,
        p_kind text, p_rate_percent integer, p_delay_ms integer, p_reason text,
        p_ttl_seconds integer, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, fault_injection_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_existing relay.fault_injections;
      BEGIN
        IF p_scope_kind IS NULL OR p_scope_kind NOT IN ('installation', 'tenant')
          OR p_target_environment IS NULL OR p_target_environment NOT IN ('live', 'test')
          OR p_kind IS NULL OR p_kind NOT IN ('provider_auth_error', 'rate_limited_429',
            'concurrency_exhausted', 'bounce_spike', 'template_paused',
            'delayed_delivery_report', 'iys_pull_stalled', 'added_latency')
          OR p_rate_percent IS NULL OR p_rate_percent NOT BETWEEN 0 AND 100
          OR p_ttl_seconds IS NULL OR p_ttl_seconds NOT BETWEEN 1 AND 3600
          OR (p_kind IN ('added_latency', 'delayed_delivery_report')) <> (p_delay_ms IS NOT NULL)
          OR p_delay_ms NOT BETWEEN 1 AND 3600000
          OR (p_kind = 'added_latency' AND p_delay_ms > 10000)
          OR (p_kind = 'iys_pull_stalled' AND (p_channel IS NOT NULL OR p_provider IS NOT NULL))
          OR p_provider !~ '^[a-z][a-z0-9_]{0,63}$'
          OR char_length(p_reason) > 2000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-92';
        END IF;
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
          RETURN QUERY SELECT 'reason_required'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_tenant IS DISTINCT FROM relay_private.installation_tenant_id() OR v_env <> 'live'
          OR (p_scope_kind = 'tenant') <> (p_scope_tenant_id IS NOT NULL) THEN
          RETURN QUERY SELECT 'invalid_scope'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT * INTO v_existing FROM relay.fault_injections f
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_id;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, p_id;
          RETURN;
        END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended('relay.fault_injections', 0));
        SELECT * INTO v_existing FROM relay.fault_injections f
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.status = 'active'
            AND f.expires_at > now() AND f.scope_kind = p_scope_kind
            AND f.scope_tenant_id IS NOT DISTINCT FROM p_scope_tenant_id
            AND f.target_environment = p_target_environment::relay.environment
            AND f.channel IS NOT DISTINCT FROM p_channel::relay.channel
            AND f.provider IS NOT DISTINCT FROM p_provider AND f.kind = p_kind
            AND f.rate_percent = p_rate_percent AND f.delay_ms IS NOT DISTINCT FROM p_delay_ms
          ORDER BY f.created_at
          LIMIT 1;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_existing.id;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.fault_injections (tenant_id, environment, id, scope_kind,
          scope_tenant_id, target_environment, channel, provider, kind, rate_percent, delay_ms,
          reason, created_by_ref, expires_at, status, cleared_at, cleared_by_ref, clear_reason,
          created_at)
        VALUES (v_tenant, v_env, p_id, p_scope_kind, p_scope_tenant_id,
          p_target_environment::relay.environment, p_channel::relay.channel, p_provider, p_kind,
          p_rate_percent, p_delay_ms, p_reason, p_actor_ref,
          now() + make_interval(secs => p_ttl_seconds), 'active', NULL, NULL, NULL, now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'fault_injection.engaged',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'fault_injection',
          p_id::text, p_reason, p_record_digest);
        RETURN QUERY SELECT 'engaged'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.fault_injection_clear(p_id uuid, p_reason text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_record relay.fault_injections;
      BEGIN
        IF p_id IS NULL OR char_length(p_reason) > 2000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-92';
        END IF;
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
          RETURN 'reason_required';
        END IF;
        SELECT * INTO v_record FROM relay.fault_injections f
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_record.status = 'cleared' THEN
          RETURN 'already_cleared';
        END IF;
        UPDATE relay.fault_injections f SET status = 'cleared', cleared_at = now(),
            cleared_by_ref = p_actor_ref, clear_reason = p_reason
          WHERE f.tenant_id = v_tenant AND f.environment = v_env AND f.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'fault_injection.cleared',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'fault_injection',
          p_id::text, p_reason, p_record_digest);
        RETURN 'cleared';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.fault_injection_list(p_include_inactive boolean, p_limit integer)
        RETURNS SETOF relay.fault_injections
      LANGUAGE sql STABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT f.* FROM relay.fault_injections f
        WHERE f.tenant_id = relay_private.ctx_tenant_id()
          AND f.environment = relay_private.ctx_environment()
          AND (p_include_inactive OR (f.status = 'active' AND f.expires_at > now()))
        ORDER BY f.id DESC
        LIMIT least(greatest(coalesce(p_limit, 100), 1), 1000)
      $fn$
      """
    ]
  end
end
