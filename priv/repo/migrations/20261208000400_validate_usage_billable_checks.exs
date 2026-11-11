defmodule Relay.Repo.Migrations.ValidateUsageBillableChecks do
  use Ecto.Migration

  # DS-53
  # OP-57 (3)
  def up do
    execute(
      "ALTER TABLE relay.usage_records VALIDATE CONSTRAINT usage_records_billable_unit_check"
    )

    execute(
      "ALTER TABLE relay.usage_records VALIDATE CONSTRAINT usage_records_billable_units_check"
    )

    execute(
      "ALTER TABLE relay.usage_records VALIDATE CONSTRAINT usage_records_voice_seconds_check"
    )
  end

  def down, do: :ok
end
