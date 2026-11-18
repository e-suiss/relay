defmodule Relay.Repo.Migrations.IndexEventsByCorrelationId do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # OP-94
  # OP-57 (3)
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS events_correlation_id_index
      ON relay.events (tenant_id, environment, correlation_id)
      WHERE correlation_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS relay.events_correlation_id_index")
  end
end
