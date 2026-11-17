defmodule Relay.Repo.Migrations.ValidateTransientRecipientCheck do
  use Ecto.Migration

  # OP-57
  # E-108
  def up do
    execute("ALTER TABLE relay.recipients VALIDATE CONSTRAINT recipients_transient_check")
  end

  def down, do: :ok
end
