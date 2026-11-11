defmodule Relay.Repo.Migrations.ValidateEventTimingPrecisionCheck do
  use Ecto.Migration

  # OP-57
  # WF-58
  def up do
    execute("ALTER TABLE relay.events VALIDATE CONSTRAINT events_timing_precision_check")
  end

  def down, do: :ok
end
