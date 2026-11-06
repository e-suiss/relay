defmodule Relay.Repo.Migrations.CreateProviderSettingsCheckScopes do
  use Ecto.Migration

  @signature "relay_ops.provider_settings_check_scopes(text[], bigint, integer)"

  # CH-52
  # TN-13 (4)
  def up do
    execute(~S"""
    CREATE FUNCTION relay_ops.provider_settings_check_scopes(p_providers text[],
      p_interval_s bigint, p_limit integer)
      RETURNS TABLE (tenant_id uuid, environment text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT DISTINCT a.tenant_id, a.environment::text
      FROM relay.provider_accounts a
      WHERE a.state = 'active'
        AND a.verification_state = 'verified'
        AND a.provider = ANY (COALESCE(p_providers, ARRAY[]::text[]))
        AND (a.health_checked_at IS NULL
          OR a.health_checked_at <= now() - GREATEST(COALESCE(p_interval_s, 0), 0)
            * interval '1 second')
      LIMIT GREATEST(COALESCE(p_limit, 100), 1)
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_worker")
  end

  def down, do: :ok
end
