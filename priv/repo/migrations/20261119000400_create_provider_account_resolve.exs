defmodule Relay.Repo.Migrations.CreateProviderAccountResolve do
  use Ecto.Migration

  @signature "relay_ops.provider_account_resolve(uuid)"

  # CH-60
  # TN-13 (4)
  def up do
    execute(~S"""
    CREATE FUNCTION relay_ops.provider_account_resolve(p_provider_account_id uuid)
      RETURNS TABLE (tenant_id uuid, environment text, provider text, channel text, state text,
        tenant_status text, settings jsonb)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT a.tenant_id, a.environment::text, a.provider, a.channel::text, a.state, t.status,
        a.settings
      FROM relay.provider_accounts a
      JOIN relay.tenants t ON t.id = a.tenant_id
      WHERE a.id = p_provider_account_id
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_api, relay_worker")
  end

  def down, do: :ok
end
