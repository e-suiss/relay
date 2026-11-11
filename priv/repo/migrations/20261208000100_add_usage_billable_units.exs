defmodule Relay.Repo.Migrations.AddUsageBillableUnits do
  use Ecto.Migration

  # DS-53
  # OP-38
  # OP-57 (3)
  def up do
    execute("""
    ALTER TABLE relay.usage_records
      ADD COLUMN billable_unit text,
      ADD COLUMN billable_units bigint,
      ADD COLUMN voice_seconds bigint
    """)

    execute("""
    ALTER TABLE relay.usage_records ADD CONSTRAINT usage_records_billable_unit_check
      CHECK (billable_unit IN ('segment', 'answered_call', 'message', 'recipient', 'attempt'))
      NOT VALID
    """)

    execute("""
    ALTER TABLE relay.usage_records ADD CONSTRAINT usage_records_billable_units_check
      CHECK ((billable_unit IS NULL) = (billable_units IS NULL) AND billable_units >= 0) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.usage_records ADD CONSTRAINT usage_records_voice_seconds_check
      CHECK (voice_seconds IS NULL OR (channel = 'voice' AND voice_seconds >= 0)) NOT VALID
    """)
  end

  def down, do: :ok
end
