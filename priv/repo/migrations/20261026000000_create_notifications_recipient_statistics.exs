defmodule Relay.Repo.Migrations.CreateNotificationsRecipientStatistics do
  use Ecto.Migration

  # OP-72 (4)
  # OP-71 (3)
  def up do
    execute("""
    CREATE STATISTICS relay.notifications_recipient_dependencies (dependencies)
      ON tenant_id, environment, recipient_id FROM relay.notifications
    """)

    execute("ANALYZE relay.notifications")
  end

  def down do
    execute("DROP STATISTICS relay.notifications_recipient_dependencies")
  end
end
