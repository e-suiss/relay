defmodule Relay.Repo.Migrations.ValidateProviderAccountArchivedState do
  use Ecto.Migration

  # C-45
  # OP-57 (3)
  def up do
    execute(
      "ALTER TABLE relay.provider_accounts VALIDATE CONSTRAINT provider_accounts_state_archived_check"
    )

    execute("ALTER TABLE relay.provider_accounts DROP CONSTRAINT provider_accounts_state_check")
  end

  def down, do: :ok
end
