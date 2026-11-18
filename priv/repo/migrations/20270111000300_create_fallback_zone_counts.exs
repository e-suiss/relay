defmodule Relay.Repo.Migrations.CreateFallbackZoneCounts do
  use Ecto.Migration

  @tenant_match "tenant_id = (select current_setting('relay.tenant_id')::uuid) AND environment = (select current_setting('relay.environment')::relay.environment)"
  @context_guard "(select current_setting('relay.tenant_id')::uuid) IS NOT NULL AND (select current_setting('relay.environment')::relay.environment) IS NOT NULL"
  @tenant_scope "#{@tenant_match} AND #{@context_guard}"
  @add "relay_fn.fallback_zone_count_add(text)"

  # X-6
  # WF-46
  # PC-48
  # TN-12
  # TN-13
  def up do
    execute(~S"""
    CREATE TABLE relay.fallback_zone_counts (
      tenant_id uuid NOT NULL,
      environment relay.environment NOT NULL,
      count_day date NOT NULL,
      source text NOT NULL
        CONSTRAINT fallback_zone_counts_source_check
          CHECK (source IN ('device', 'country', 'tenant_default')),
      deliveries bigint NOT NULL
        CONSTRAINT fallback_zone_counts_deliveries_check CHECK (deliveries >= 1),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT fallback_zone_counts_pkey PRIMARY KEY (tenant_id, environment, count_day, source)
    )
    """)

    execute("""
    CREATE TRIGGER fallback_zone_counts_no_delete BEFORE DELETE ON relay.fallback_zone_counts
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER fallback_zone_counts_no_truncate BEFORE TRUNCATE ON relay.fallback_zone_counts
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("ALTER TABLE relay.fallback_zone_counts ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE relay.fallback_zone_counts FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY fallback_zone_counts_scope ON relay.fallback_zone_counts USING (#{@tenant_scope}) WITH CHECK (#{@tenant_scope})"
    )

    execute("GRANT SELECT, INSERT, UPDATE ON relay.fallback_zone_counts TO relay_owner")

    execute(
      "GRANT SELECT ON relay.fallback_zone_counts TO relay_app, relay_maint, relay_archive, relay_report"
    )

    execute(~S"""
    CREATE FUNCTION relay_fn.fallback_zone_count_add(p_source text) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
    BEGIN
      IF p_source IS NULL OR p_source NOT IN ('device', 'country', 'tenant_default') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WF-46';
      END IF;
      INSERT INTO relay.fallback_zone_counts AS c (tenant_id, environment, count_day, source,
          deliveries, created_at, updated_at)
        VALUES (v_tenant, v_env, now()::date, p_source, 1, now(), now())
        ON CONFLICT (tenant_id, environment, count_day, source)
        DO UPDATE SET deliveries = c.deliveries + 1, updated_at = now();
      RETURN 'counted';
    END
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@add} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@add} TO relay_app")
    execute("ALTER FUNCTION #{@add} OWNER TO relay_owner")
  end

  def down, do: :ok
end
