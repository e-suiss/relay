defmodule Relay.Repo.Migrations.ValidateMailboxRecordKindChecks do
  use Ecto.Migration

  # AG-59
  # AG-61
  # OP-57
  def up do
    execute("ALTER TABLE relay.mailbox_records VALIDATE CONSTRAINT mailbox_records_kind_check")
    execute("ALTER TABLE relay.mailbox_records VALIDATE CONSTRAINT mailbox_records_held_check")
  end

  def down, do: :ok
end
