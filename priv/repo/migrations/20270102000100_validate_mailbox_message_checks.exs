defmodule Relay.Repo.Migrations.ValidateMailboxMessageChecks do
  use Ecto.Migration

  # OP-57
  # AG-69
  # AG-70
  def up do
    execute(
      "ALTER TABLE relay.mailbox_records VALIDATE CONSTRAINT mailbox_records_trust_label_check"
    )

    execute(
      "ALTER TABLE relay.mailbox_records VALIDATE CONSTRAINT mailbox_records_content_ref_ct_check"
    )
  end

  def down, do: :ok
end
