defmodule Relay.Repo.Migrations.AddInstallationJsonbSizeChecks do
  use Ecto.Migration

  # OP-1
  # OP-57 (3)
  # OP-71 (8)
  def up do
    execute("""
    ALTER TABLE relay.datasets
      ADD CONSTRAINT datasets_json_schema_check CHECK (pg_column_size(json_schema) <= 65536) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.singleton_tasks
      ADD CONSTRAINT singleton_tasks_state_check CHECK (pg_column_size(state) <= 65536) NOT VALID
    """)
  end

  def down do
    execute("ALTER TABLE relay.singleton_tasks DROP CONSTRAINT singleton_tasks_state_check")
    execute("ALTER TABLE relay.datasets DROP CONSTRAINT datasets_json_schema_check")
  end
end
