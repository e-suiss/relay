defmodule Relay.Repo.Migrations.ValidateRecurrenceHandoffChecks do
  use Ecto.Migration

  # OP-57
  # OP-97
  def up do
    execute("ALTER TABLE relay.recurrences VALIDATE CONSTRAINT recurrences_handoff_cursor_check")
    execute("ALTER TABLE relay.recurrences VALIDATE CONSTRAINT recurrences_handoff_check")
  end

  def down, do: :ok
end
