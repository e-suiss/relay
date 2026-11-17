defmodule Relay.Repo.Migrations.ValidateIysChecks do
  use Ecto.Migration

  # OP-57
  # PC-30
  # PC-29
  def up do
    execute("ALTER TABLE relay.consents VALIDATE CONSTRAINT consents_status_check")
    execute("ALTER TABLE relay.secret_refs VALIDATE CONSTRAINT secret_refs_kind_check")
  end

  def down, do: :ok
end
