defmodule Relay.Repo.Migrations.ValidateDeviceInterruptionPermissionsCheck do
  use Ecto.Migration

  # OP-57
  # CH-65
  def up do
    execute(
      "ALTER TABLE relay.devices VALIDATE CONSTRAINT devices_interruption_permissions_check"
    )
  end

  def down, do: :ok
end
