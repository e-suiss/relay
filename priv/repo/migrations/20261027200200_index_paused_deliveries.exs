defmodule Relay.Repo.Migrations.IndexPausedDeliveries do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # TN-40
  # OP-57 (3)
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS deliveries_pause_kill_switch_id_index
      ON relay.deliveries (tenant_id, environment, pause_kill_switch_id) WHERE paused_at IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS relay.deliveries_pause_kill_switch_id_index")
  end
end
