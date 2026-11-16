defmodule Relay.Repo.Migrations.AddDeliveryStepRef do
  use Ecto.Migration

  # WF-63
  # OP-57
  def up do
    execute("""
    ALTER TABLE relay.deliveries ADD COLUMN step_ref text NOT NULL DEFAULT ''
    """)

    execute("""
    ALTER TABLE relay.deliveries ADD CONSTRAINT deliveries_step_ref_check
      CHECK (char_length(step_ref) <= 600) NOT VALID
    """)
  end

  def down, do: :ok
end
