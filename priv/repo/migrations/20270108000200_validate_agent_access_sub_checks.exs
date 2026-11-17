defmodule Relay.Repo.Migrations.ValidateAgentAccessSubChecks do
  use Ecto.Migration

  # OP-57
  # E-106
  def up do
    execute("ALTER TABLE relay.agents VALIDATE CONSTRAINT agents_access_sub_bidx_check")
    execute("ALTER TABLE relay.agents VALIDATE CONSTRAINT agents_access_sub_ct_check")
  end

  def down, do: :ok
end
