defmodule Relay.Repo.Migrations.ValidateUsageDimensionChecks do
  use Ecto.Migration

  # OP-38
  # OP-57 (3)
  def up do
    execute(
      "ALTER TABLE relay.delivery_attempts VALIDATE CONSTRAINT delivery_attempts_destination_country_check"
    )

    execute(
      "ALTER TABLE relay.delivery_attempts VALIDATE CONSTRAINT delivery_attempts_sms_segments_check"
    )

    execute(
      "ALTER TABLE relay.usage_records VALIDATE CONSTRAINT usage_records_outcome_kind_check"
    )
  end

  def down, do: :ok
end
