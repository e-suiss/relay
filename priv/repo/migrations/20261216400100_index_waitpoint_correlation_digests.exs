defmodule Relay.Repo.Migrations.IndexWaitpointCorrelationDigests do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # AG-65
  # AG-14
  # OP-57 (3)
  def up do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS waitpoints_active_digest_key
      ON relay.waitpoints (tenant_id, environment, waiter_kind, waiter_ref, match_event_type,
        correlation_digest)
      WHERE state IN ('open', 'stalled')
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS waitpoints_digest_match_index
      ON relay.waitpoints (tenant_id, environment, match_event_type, correlation_digest)
      WHERE state IN ('open', 'stalled')
    """)
  end

  def down, do: :ok
end
