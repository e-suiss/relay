defmodule Relay.Repo.Migrations.ValidateInstallationJsonbSizeChecks do
  use Ecto.Migration

  # OP-57 (3)
  # OP-71 (8)
  def up do
    execute("ALTER TABLE relay.datasets VALIDATE CONSTRAINT datasets_json_schema_check")
    execute("ALTER TABLE relay.singleton_tasks VALIDATE CONSTRAINT singleton_tasks_state_check")
  end

  def down, do: :ok
end
