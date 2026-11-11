defmodule Relay.Repo.Migrations.IndexOpenDeliveries do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # DS-48
  # OP-57 (3)
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS deliveries_open_accepted_at_index
      ON relay.deliveries (tenant_id, environment, channel, accepted_at)
      WHERE delivery_rank = 1 AND failure_kind IS NULL
    """)
  end

  def down, do: :ok
end
