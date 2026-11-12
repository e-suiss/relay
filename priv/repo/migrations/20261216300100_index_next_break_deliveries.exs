defmodule Relay.Repo.Migrations.IndexNextBreakDeliveries do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # WF-56
  # OP-57 (3)
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS deliveries_next_break_index
      ON relay.deliveries (tenant_id, environment, recipient_id)
      WHERE decision = 'defer' AND decision_rule_id = 'next_break.deferred'
    """)
  end

  def down, do: :ok
end
