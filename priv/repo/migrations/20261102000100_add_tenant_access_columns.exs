defmodule Relay.Repo.Migrations.AddTenantAccessColumns do
  use Ecto.Migration

  # TN-1
  # TN-9
  # E-9
  # OP-57 (3)
  def up do
    execute("""
    ALTER TABLE relay.tenants
      ADD COLUMN access_organization_id text,
      ADD COLUMN platform_product text
    """)

    execute("""
    ALTER TABLE relay.tenants ADD CONSTRAINT tenants_access_organization_id_check
      CHECK (char_length(access_organization_id) <= 128) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.tenants ADD CONSTRAINT tenants_platform_product_check
      CHECK (platform_product IN ('access', 'work', 'executor', 'one', 'pay')) NOT VALID
    """)
  end
end
