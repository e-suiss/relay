defmodule Relay.Repo.Migrations.AddAgentScopes do
  use Ecto.Migration

  # AG-6
  # E-82
  # API-75
  # OP-57
  def up do
    execute("ALTER DOMAIN relay.api_scope DROP CONSTRAINT api_scope_check")

    execute("""
    ALTER DOMAIN relay.api_scope ADD CONSTRAINT api_scope_check
      CHECK (VALUE IN ('publish', 'read', 'subscribers', 'config', 'kill_switch', 'agents',
        'agent:send', 'agent:waitpoint', 'agent:mailbox', 'presence:read'))
      NOT VALID
    """)

    execute("ALTER TABLE relay.api_clients DROP CONSTRAINT api_clients_scopes_check")

    execute("""
    ALTER TABLE relay.api_clients ADD CONSTRAINT api_clients_scopes_check
      CHECK (cardinality(scopes) BETWEEN 1 AND 6)
      NOT VALID
    """)

    execute("""
    ALTER TABLE relay.api_clients ADD CONSTRAINT api_clients_scope_family_check
      CHECK (NOT (scopes::text[] && ARRAY['agent:send', 'agent:waitpoint', 'agent:mailbox',
          'presence:read']
        AND scopes::text[] && ARRAY['publish', 'read', 'subscribers', 'config', 'kill_switch',
          'agents']))
      NOT VALID
    """)
  end

  def down, do: :ok
end
