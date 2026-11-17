defmodule Relay.Repo.Migrations.AllowAgentsApiScope do
  use Ecto.Migration

  # AG-49
  # E-44
  # OP-57
  def up do
    execute("ALTER DOMAIN relay.api_scope DROP CONSTRAINT api_scope_check")

    execute("""
    ALTER DOMAIN relay.api_scope ADD CONSTRAINT api_scope_check
      CHECK (VALUE IN ('publish', 'read', 'subscribers', 'config', 'kill_switch', 'agents'))
      NOT VALID
    """)

    execute("ALTER TABLE relay.api_clients DROP CONSTRAINT api_clients_scopes_check")

    execute("""
    ALTER TABLE relay.api_clients ADD CONSTRAINT api_clients_scopes_check
      CHECK (cardinality(scopes) BETWEEN 1 AND 6) NOT VALID
    """)
  end

  def down, do: :ok
end
