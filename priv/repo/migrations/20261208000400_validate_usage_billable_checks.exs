defmodule Relay.Repo.Migrations.ValidateUsageBillableChecks do
  use Ecto.Migration

  # DS-53
  # OP-57 (3)
  def up do
    for check <- ~w(billable_unit billable_units voice_seconds) do
      execute("ALTER TABLE relay.usage_records VALIDATE CONSTRAINT usage_records_#{check}_check")
    end
  end

  def down, do: :ok
end
