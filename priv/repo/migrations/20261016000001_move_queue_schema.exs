defmodule Relay.Repo.Migrations.MoveQueueSchema do
  use Ecto.Migration

  # OP-68
  def up, do: execute("ALTER SCHEMA oban RENAME TO relay_queue")

  def down, do: execute("ALTER SCHEMA relay_queue RENAME TO oban")
end
