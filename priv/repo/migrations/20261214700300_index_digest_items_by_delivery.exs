defmodule Relay.Repo.Migrations.IndexDigestItemsByDelivery do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # PC-46
  # WF-30
  # OP-57 (3)
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS digest_items_delivery_index
      ON relay.digest_items (tenant_id, environment, delivery_id) WHERE delivery_id IS NOT NULL
    """)
  end

  def down, do: :ok
end
