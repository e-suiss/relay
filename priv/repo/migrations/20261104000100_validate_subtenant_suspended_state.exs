defmodule Relay.Repo.Migrations.ValidateSubtenantSuspendedState do
  use Ecto.Migration

  # TN-10
  # OP-57 (3)
  def up do
    execute("ALTER TABLE relay.subtenants VALIDATE CONSTRAINT subtenants_state_suspended_check")
    execute("ALTER TABLE relay.subtenants DROP CONSTRAINT subtenants_state_check")
  end

  def down, do: :ok
end
