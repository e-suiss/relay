defmodule Relay.Repo.Migrations.ValidateWebhookDestinationSecretCheck do
  use Ecto.Migration

  # OP-57
  # WH-19
  def up do
    execute("ALTER TABLE relay.secret_refs VALIDATE CONSTRAINT secret_refs_kind_check")
  end

  def down, do: :ok
end
