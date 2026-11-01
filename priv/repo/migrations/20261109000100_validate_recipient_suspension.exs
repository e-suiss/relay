defmodule Relay.Repo.Migrations.ValidateRecipientSuspension do
  use Ecto.Migration

  # TN-73
  # OP-57 (3)
  def up do
    execute("SELECT set_config('relay.tenant_id', '00000000-0000-0000-0000-000000000000', true)")
    execute("SELECT set_config('relay.environment', 'live', true)")
    execute("ALTER TABLE relay.recipients VALIDATE CONSTRAINT recipients_state_check")
    execute("ALTER TABLE relay.recipients VALIDATE CONSTRAINT recipients_suspended_at_check")
  end

  def down, do: :ok
end
