defmodule Relay.Repo.Migrations.ValidateInboxOperationChecks do
  use Ecto.Migration

  # OP-57
  # IN-44
  def up do
    execute("ALTER TABLE relay.inbox_items VALIDATE CONSTRAINT inbox_items_hidden_reason_check")
    execute("ALTER TABLE relay.inbox_items VALIDATE CONSTRAINT inbox_items_retired_check")
    execute("ALTER TABLE relay.inbox_items VALIDATE CONSTRAINT inbox_items_content_check")
  end

  def down, do: :ok
end
