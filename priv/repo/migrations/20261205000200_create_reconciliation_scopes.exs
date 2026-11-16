defmodule Relay.Repo.Migrations.CreateReconciliationScopes do
  use Ecto.Migration

  @signature "relay_ops.reconciliation_scopes(text[], integer)"

  # DS-22
  # DS-48
  # TN-13 (4)
  def up do
    execute(~S"""
    CREATE FUNCTION relay_ops.reconciliation_scopes(p_providers text[], p_limit integer)
      RETURNS TABLE (tenant_id uuid, environment text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT DISTINCT a.tenant_id, a.environment::text
      FROM relay.provider_accounts a
      JOIN relay.tenants t ON t.id = a.tenant_id
      WHERE a.state = 'active'
        AND a.verification_state = 'verified'
        AND t.status = 'active'
        AND a.provider = ANY (COALESCE(p_providers, ARRAY[]::text[]))
      ORDER BY 1, 2
      LIMIT GREATEST(COALESCE(p_limit, 1000), 1)
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_worker")
  end

  def down, do: :ok
end
