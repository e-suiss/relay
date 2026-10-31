defmodule Relay.Repo.Migrations.ValidateIngressConstraints do
  use Ecto.Migration

  # OP-57 (3)
  def up do
    execute("SELECT set_config('relay.tenant_id', '00000000-0000-0000-0000-000000000000', true)")
    execute("SELECT set_config('relay.environment', 'live', true)")
    execute("ALTER TABLE relay.recipients VALIDATE CONSTRAINT recipients_state_check")
    execute("ALTER TABLE relay.recipients VALIDATE CONSTRAINT recipients_locale_check")
    execute("ALTER TABLE relay.recipients VALIDATE CONSTRAINT recipients_timezone_check")
    execute("ALTER TABLE relay.recipients VALIDATE CONSTRAINT recipients_legal_type_check")
    execute("ALTER TABLE relay.recipients VALIDATE CONSTRAINT recipients_version_check")
    execute("ALTER TABLE relay.recipients VALIDATE CONSTRAINT recipients_profile_key_id_fkey")

    execute("ALTER TABLE relay.notifications VALIDATE CONSTRAINT notifications_event_id_fkey")
    execute("ALTER TABLE relay.notifications VALIDATE CONSTRAINT notifications_workflow_id_fkey")

    execute(
      "ALTER TABLE relay.notifications VALIDATE CONSTRAINT notifications_workflow_version_id_fkey"
    )
  end

  def down, do: :ok
end
