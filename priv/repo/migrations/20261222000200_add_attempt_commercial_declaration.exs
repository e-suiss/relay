defmodule Relay.Repo.Migrations.AddAttemptCommercialDeclaration do
  use Ecto.Migration

  # PC-4
  def up do
    execute("""
    ALTER TABLE relay.delivery_attempts
      ADD COLUMN commercial boolean,
      ADD COLUMN iys_recipient_type text
    """)

    execute("""
    ALTER TABLE relay.delivery_attempts
      ADD CONSTRAINT delivery_attempts_iys_recipient_type_check
      CHECK (iys_recipient_type IN ('BIREYSEL', 'TACIR')) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.delivery_attempts
      ADD CONSTRAINT delivery_attempts_commercial_declaration_check
      CHECK (iys_recipient_type IS NULL OR commercial IS TRUE) NOT VALID
    """)
  end

  def down, do: :ok
end
