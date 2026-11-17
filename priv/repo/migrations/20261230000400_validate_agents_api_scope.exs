defmodule Relay.Repo.Migrations.ValidateAgentsApiScope do
  use Ecto.Migration

  # AG-49
  # OP-57
  def up do
    execute("ALTER DOMAIN relay.api_scope VALIDATE CONSTRAINT api_scope_check")
    execute("ALTER TABLE relay.api_clients VALIDATE CONSTRAINT api_clients_scopes_check")
  end

  def down, do: :ok
end
