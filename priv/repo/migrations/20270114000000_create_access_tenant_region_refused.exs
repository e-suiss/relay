defmodule Relay.Repo.Migrations.CreateAccessTenantRegionRefused do
  use Ecto.Migration

  @signature "relay_ops.access_tenant_region_refused(text)"

  # OP-90
  # INV-41
  # API-7
  def up do
    execute(~S"""
    CREATE FUNCTION relay_ops.access_tenant_region_refused(p_access_tenant_id text)
      RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT p_access_tenant_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM relay.tenants t
          WHERE t.access_tenant_id = p_access_tenant_id AND t.kind = 'tenant')
        AND EXISTS (SELECT 1 FROM relay.access_event_receipts r
          WHERE r.access_tenant_id = p_access_tenant_id AND r.state = 'rejected'
            AND r.reason = 'region_mismatch')
    $fn$
    """)

    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_api, relay_worker")
  end

  def down, do: :ok
end
