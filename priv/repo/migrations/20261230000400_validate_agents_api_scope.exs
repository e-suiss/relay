defmodule Relay.Repo.Migrations.ValidateAgentsApiScope do
  use Ecto.Migration

  # AG-49
  # OP-57
  def up do
    execute("ALTER TABLE relay.api_clients VALIDATE CONSTRAINT api_clients_scopes_check")
  end

  def down, do: :ok
end
