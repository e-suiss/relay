defmodule Relay.Repo.Migrations.IndexRenderDigests do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # WF-35
  # OP-57 (3)
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS delivery_render_plans_render_digest_index
      ON relay.delivery_render_plans (tenant_id, environment, render_digest, rendered_at)
      WHERE render_digest IS NOT NULL
    """)
  end

  def down, do: :ok
end
