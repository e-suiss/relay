defmodule Relay.Repo.Migrations.AddTenantApiVersion do
  use Ecto.Migration

  # API-52
  # OP-57 (3)
  def up do
    execute("""
    ALTER TABLE relay.tenants
      ADD COLUMN api_version date,
      ADD COLUMN api_version_pinned_at timestamptz
    """)

    execute("""
    ALTER TABLE relay.tenants ADD CONSTRAINT tenants_api_version_pinned_at_check
      CHECK ((api_version IS NULL) = (api_version_pinned_at IS NULL)) NOT VALID
    """)
  end
end
