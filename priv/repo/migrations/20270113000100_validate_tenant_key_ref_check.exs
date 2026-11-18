defmodule Relay.Repo.Migrations.ValidateTenantKeyRefCheck do
  use Ecto.Migration

  # OP-57
  # OP-85
  def up do
    execute("ALTER TABLE relay.tenants VALIDATE CONSTRAINT tenants_key_ref_check")
  end

  def down, do: :ok
end
