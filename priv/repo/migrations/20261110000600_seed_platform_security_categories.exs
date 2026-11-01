defmodule Relay.Repo.Migrations.SeedPlatformSecurityCategories do
  use Ecto.Migration

  # PC-57 (3)
  # API-81
  # E-10
  # PC-6
  def up do
    execute(category_seed())
    execute("REVOKE ALL ON FUNCTION relay_private.security_category_seed() FROM PUBLIC")

    execute("""
    CREATE TRIGGER tenants_security_category AFTER INSERT ON relay.tenants
      FOR EACH ROW WHEN (NEW.platform_product = 'access')
      EXECUTE FUNCTION relay_private.security_category_seed()
    """)

    execute("ALTER TABLE relay.tenants NO FORCE ROW LEVEL SECURITY")
    execute(backfill())
    execute("ALTER TABLE relay.tenants FORCE ROW LEVEL SECURITY")
  end

  def down, do: :ok

  defp category_seed do
    ~S"""
    CREATE FUNCTION relay_private.security_category_seed() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_saved_tenant text;
      v_saved_environment text;
      v_env text;
    BEGIN
      SELECT s.setting INTO v_saved_tenant FROM pg_settings s WHERE s.name = 'relay.tenant_id';
      SELECT s.setting INTO v_saved_environment FROM pg_settings s
        WHERE s.name = 'relay.environment';
      FOREACH v_env IN ARRAY ARRAY['live', 'test'] LOOP
        PERFORM set_config('relay.tenant_id', NEW.id::text, true);
        PERFORM set_config('relay.environment', v_env, true);
        INSERT INTO relay.categories (tenant_id, environment, id, key, name, message_class, locked,
          enabled, channel_defaults, default_expires_in, frequency_limit, frequency_window,
          frequency_fate, digest_allowed, builtin, state, archived_at, version, created_at,
          updated_at)
        VALUES (NEW.id, v_env, uuidv7(), 'security', 'Security', 'security', true, true, '{}',
          NULL, NULL, NULL, NULL, false, true, 'active', NULL, 1, now(), now())
        ON CONFLICT (tenant_id, environment, key) DO NOTHING;
      END LOOP;
      PERFORM set_config('relay.tenant_id', COALESCE(v_saved_tenant, ''), true);
      PERFORM set_config('relay.environment', COALESCE(v_saved_environment, ''), true);
      RETURN NULL;
    END
    $fn$
    """
  end

  defp backfill do
    ~S"""
    DO $$
    DECLARE
      v_tenant uuid;
      v_env text;
    BEGIN
      FOR v_tenant IN SELECT t.id FROM relay.tenants t WHERE t.platform_product = 'access'
        ORDER BY t.id
      LOOP
        FOREACH v_env IN ARRAY ARRAY['live', 'test'] LOOP
          PERFORM set_config('relay.tenant_id', v_tenant::text, true);
          PERFORM set_config('relay.environment', v_env, true);
          INSERT INTO relay.categories (tenant_id, environment, id, key, name, message_class,
            locked, enabled, channel_defaults, default_expires_in, frequency_limit,
            frequency_window, frequency_fate, digest_allowed, builtin, state, archived_at, version,
            created_at, updated_at)
          VALUES (v_tenant, v_env, uuidv7(), 'security', 'Security', 'security', true, true, '{}',
            NULL, NULL, NULL, NULL, false, true, 'active', NULL, 1, now(), now())
          ON CONFLICT (tenant_id, environment, key) DO NOTHING;
        END LOOP;
      END LOOP;
    END
    $$
    """
  end
end
