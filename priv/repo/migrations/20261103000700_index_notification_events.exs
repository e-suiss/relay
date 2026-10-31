defmodule Relay.Repo.Migrations.IndexNotificationEvents do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # API-57
  # OP-57 (3)
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS notifications_event_id_index
      ON relay.notifications (tenant_id, environment, event_id) WHERE event_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS relay.notifications_event_id_index")
  end
end
