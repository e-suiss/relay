defmodule Relay.Repo.Migrations.ValidateEvidenceLevelRejections do
  use Ecto.Migration

  # AG-62
  # OP-57 (3)
  def up do
    execute("""
    ALTER TABLE relay.waitpoint_response_rejections
      VALIDATE CONSTRAINT waitpoint_response_rejections_reason_kind_check
    """)
  end

  def down, do: :ok
end
