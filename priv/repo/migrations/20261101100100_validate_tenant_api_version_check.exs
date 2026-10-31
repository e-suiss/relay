defmodule Relay.Repo.Migrations.ValidateTenantApiVersionCheck do
  use Ecto.Migration

  # OP-57 (3)
  def up do
    execute("ALTER TABLE relay.tenants VALIDATE CONSTRAINT tenants_api_version_pinned_at_check")
  end

  def down, do: :ok
end
