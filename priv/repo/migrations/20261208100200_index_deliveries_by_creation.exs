defmodule Relay.Repo.Migrations.IndexDeliveriesByCreation do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # DS-35
  # OP-57 (3)
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS deliveries_created_at_index
      ON relay.deliveries (tenant_id, environment, created_at)
    """)
  end

  def down, do: :ok
end
