defmodule Relay.Repo.Migrations.AddRecipientSuspension do
  use Ecto.Migration

  # TN-73
  # OP-57 (3)
  def up do
    execute("ALTER TABLE relay.recipients ADD COLUMN suspended_at timestamptz")
    execute("ALTER TABLE relay.recipients DROP CONSTRAINT recipients_state_check")

    execute(~S"""
    ALTER TABLE relay.recipients ADD CONSTRAINT recipients_state_check
      CHECK (state IN ('active', 'suspended', 'deletion_requested', 'deleted')) NOT VALID
    """)

    execute(~S"""
    ALTER TABLE relay.recipients ADD CONSTRAINT recipients_suspended_at_check
      CHECK (state <> 'suspended' OR suspended_at IS NOT NULL) NOT VALID
    """)
  end

  def down, do: :ok
end
