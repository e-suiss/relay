defmodule Relay.Repo.Migrations.ValidateIysUploadAccessRecordCheck do
  use Ecto.Migration

  # OP-57
  # E-109
  def up do
    execute("ALTER TABLE relay.iys_uploads VALIDATE CONSTRAINT iys_uploads_access_record_check")
  end

  def down, do: :ok
end
