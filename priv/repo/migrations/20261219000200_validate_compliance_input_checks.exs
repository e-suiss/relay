defmodule Relay.Repo.Migrations.ValidateComplianceInputChecks do
  use Ecto.Migration

  # OP-57
  # PC-40
  # WF-45
  def up do
    execute("ALTER TABLE relay.recipients VALIDATE CONSTRAINT recipients_country_check")

    execute(
      "ALTER TABLE relay.recipient_addresses VALIDATE CONSTRAINT recipient_addresses_calling_code_check"
    )

    execute("ALTER TABLE relay.devices VALIDATE CONSTRAINT devices_time_zone_check")
  end

  def down, do: :ok
end
