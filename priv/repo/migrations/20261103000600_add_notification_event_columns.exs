defmodule Relay.Repo.Migrations.AddNotificationEventColumns do
  use Ecto.Migration

  # WF-6
  # WF-7
  # C-28
  # OP-57 (3)
  def up do
    execute("""
    ALTER TABLE relay.notifications
      ADD COLUMN event_id uuid,
      ADD COLUMN workflow_id uuid,
      ADD COLUMN workflow_version_id uuid
    """)

    execute("""
    ALTER TABLE relay.notifications ADD CONSTRAINT notifications_event_id_fkey
      FOREIGN KEY (tenant_id, environment, event_id)
      REFERENCES relay.events (tenant_id, environment, id)
      ON DELETE RESTRICT ON UPDATE RESTRICT NOT VALID
    """)

    execute("""
    ALTER TABLE relay.notifications ADD CONSTRAINT notifications_workflow_id_fkey
      FOREIGN KEY (tenant_id, environment, workflow_id)
      REFERENCES relay.workflows (tenant_id, environment, id)
      ON DELETE RESTRICT ON UPDATE RESTRICT NOT VALID
    """)

    execute("""
    ALTER TABLE relay.notifications ADD CONSTRAINT notifications_workflow_version_id_fkey
      FOREIGN KEY (tenant_id, environment, workflow_version_id)
      REFERENCES relay.workflow_versions (tenant_id, environment, id)
      ON DELETE RESTRICT ON UPDATE RESTRICT NOT VALID
    """)
  end
end
