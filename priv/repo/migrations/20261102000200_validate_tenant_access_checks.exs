defmodule Relay.Repo.Migrations.ValidateTenantAccessChecks do
  use Ecto.Migration

  # OP-57 (3)
  def up do
    execute("ALTER TABLE relay.tenants VALIDATE CONSTRAINT tenants_access_organization_id_check")
    execute("ALTER TABLE relay.tenants VALIDATE CONSTRAINT tenants_platform_product_check")
  end

  def down, do: :ok
end
