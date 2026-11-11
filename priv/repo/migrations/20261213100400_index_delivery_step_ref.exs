defmodule Relay.Repo.Migrations.IndexDeliveryStepRef do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # WF-63
  # OP-57 (3)
  def up do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS deliveries_step_key
      ON relay.deliveries (tenant_id, environment, notification_id, channel, target_key, step_ref)
    """)
  end

  def down, do: :ok
end
