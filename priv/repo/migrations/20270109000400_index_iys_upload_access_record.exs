defmodule Relay.Repo.Migrations.IndexIysUploadAccessRecord do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # E-109
  # API-31
  def up do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS iys_uploads_access_record_key
      ON relay.iys_uploads (tenant_id, environment, access_record)
      WHERE access_record IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS relay.iys_uploads_access_record_key")
  end
end
