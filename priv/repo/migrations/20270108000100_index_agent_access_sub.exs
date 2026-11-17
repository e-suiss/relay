defmodule Relay.Repo.Migrations.IndexAgentAccessSub do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # E-106
  # AG-75
  # OP-57 (3)
  def up do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS agents_access_sub_bidx_key
      ON relay.agents (tenant_id, environment, access_sub_bidx)
      WHERE access_sub_bidx IS NOT NULL
    """)
  end

  def down, do: :ok
end
