defmodule Relay.Repo.Migrations.ValidateRecordChecks do
  use Ecto.Migration

  # OP-57
  # DS-44
  # OP-24
  # TN-60
  def up do
    execute(
      "ALTER TABLE relay.notifications VALIDATE CONSTRAINT notifications_retention_class_check"
    )

    execute("ALTER TABLE relay.deliveries VALIDATE CONSTRAINT deliveries_retention_class_check")
    execute("ALTER TABLE relay.inbox_items VALIDATE CONSTRAINT inbox_items_hidden_reason_check")

    execute(
      "ALTER TABLE relay.digest_windows VALIDATE CONSTRAINT digest_windows_close_reason_check"
    )
  end

  def down, do: :ok
end
