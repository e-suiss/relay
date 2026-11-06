defmodule Relay.Repo.Migrations.AddAttemptUsageDimensions do
  use Ecto.Migration

  # OP-38
  def up do
    execute("""
    ALTER TABLE relay.delivery_attempts
      ADD COLUMN destination_country text,
      ADD COLUMN sms_segments bigint
    """)

    execute("""
    ALTER TABLE relay.delivery_attempts ADD CONSTRAINT delivery_attempts_destination_country_check
      CHECK (destination_country ~ '^[A-Z]{2}$') NOT VALID
    """)

    execute("""
    ALTER TABLE relay.delivery_attempts ADD CONSTRAINT delivery_attempts_sms_segments_check
      CHECK (sms_segments >= 1) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.usage_records ADD CONSTRAINT usage_records_outcome_kind_check
      CHECK (outcome IN ('accepted', 'uncertain', 'failed', 'late_adjustment')) NOT VALID
    """)

    execute("ALTER TABLE relay.usage_records DROP CONSTRAINT usage_records_outcome_check")
  end

  def down, do: :ok
end
