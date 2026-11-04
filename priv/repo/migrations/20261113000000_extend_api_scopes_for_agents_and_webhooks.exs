defmodule Relay.Repo.Migrations.ExtendApiScopesForAgentsAndWebhooks do
  use Ecto.Migration

  # E-82
  # E-87
  # API-75
  def up do
    execute("ALTER DOMAIN relay.api_scope DROP CONSTRAINT api_scope_check")

    execute(~S"""
    ALTER DOMAIN relay.api_scope ADD CONSTRAINT api_scope_check
      CHECK (VALUE IN ('publish', 'read', 'subscribers', 'config', 'kill_switch', 'agents',
        'webhooks'))
    """)
  end
end
