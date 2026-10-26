defmodule Relay.Repo.Migrations.AddRecipientKindKey do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # IN-1
  # AG-64
  # OP-57
  def up do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS recipients_id_kind_key
      ON relay.recipients (tenant_id, environment, id, kind)
    """)

    execute("""
    ALTER TABLE relay.recipients
      ADD CONSTRAINT recipients_id_kind_key UNIQUE USING INDEX recipients_id_kind_key
    """)
  end

  def down do
    execute("ALTER TABLE relay.recipients DROP CONSTRAINT recipients_id_kind_key")
  end
end
