defmodule Relay.Repo.Migrations.ValidateCommercialDeclarationChecks do
  use Ecto.Migration

  # PC-4
  # OP-57 (3)
  def up do
    execute(
      "ALTER TABLE relay.delivery_attempts VALIDATE CONSTRAINT delivery_attempts_iys_recipient_type_check"
    )

    execute(
      "ALTER TABLE relay.delivery_attempts VALIDATE CONSTRAINT delivery_attempts_commercial_declaration_check"
    )
  end

  def down, do: :ok
end
