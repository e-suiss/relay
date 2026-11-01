defmodule Relay.Repo.Migrations.AddRecipientSuspension do
  use Ecto.Migration

  # TN-73
  # OP-57 (3)
  def up do
    execute("ALTER TABLE relay.recipients ADD COLUMN suspended_at timestamptz")
  end

  def down do
    execute("ALTER TABLE relay.recipients DROP COLUMN suspended_at")
  end
end
