defmodule Relay.Repo.Migrations.ValidateAgentScopeChecks do
  use Ecto.Migration

  # AG-6
  # OP-57
  def up do
    execute("ALTER TABLE relay.api_clients VALIDATE CONSTRAINT api_clients_scope_names_check")
    execute("ALTER TABLE relay.api_clients VALIDATE CONSTRAINT api_clients_scopes_check")
    execute("ALTER TABLE relay.api_clients VALIDATE CONSTRAINT api_clients_scope_family_check")
  end

  def down, do: :ok
end
