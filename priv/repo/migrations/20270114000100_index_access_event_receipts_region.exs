defmodule Relay.Repo.Migrations.IndexAccessEventReceiptsRegion do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # OP-90
  # INV-41
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS access_event_receipts_region_refused_idx
      ON relay.access_event_receipts (access_tenant_id)
      WHERE state = 'rejected' AND reason = 'region_mismatch'
    """)
  end

  def down, do: :ok
end
