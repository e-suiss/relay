defmodule Relay.Repo.Migrations.IndexDeliveryWindows do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # DS-18
  # DS-19
  # OP-57 (3)
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS deliveries_window_index
      ON relay.deliveries (tenant_id, environment, accepted_at)
      WHERE delivery_rank = 1 AND failure_kind IS NULL AND window_stage < 2
        AND channel IN ('sms', 'email', 'whatsapp', 'voice')
    """)
  end

  def down, do: :ok
end
