defmodule Relay.Repo.Migrations.ValidateRefusalSuppressionCheck do
  use Ecto.Migration

  # OP-57
  # PC-39
  def up do
    execute("ALTER TABLE relay.suppressions VALIDATE CONSTRAINT suppressions_reason_check")
  end

  def down, do: :ok
end
