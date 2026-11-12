defmodule Relay.Repo.Migrations.ValidateNextBreakChecks do
  use Ecto.Migration

  # OP-57
  # WF-56
  def up do
    execute("ALTER TABLE relay.events VALIDATE CONSTRAINT events_timing_check")
    execute("ALTER TABLE relay.events VALIDATE CONSTRAINT events_max_defer_until_check")
  end

  def down, do: :ok
end
