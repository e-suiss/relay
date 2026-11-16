defmodule Relay.Repo.Migrations.ValidateCategoryDensityChecks do
  use Ecto.Migration

  # OP-57
  # WF-30
  def up do
    execute("ALTER TABLE relay.categories VALIDATE CONSTRAINT categories_density_check")
    execute("ALTER TABLE relay.digest_windows VALIDATE CONSTRAINT digest_windows_origin_check")
  end

  def down, do: :ok
end
