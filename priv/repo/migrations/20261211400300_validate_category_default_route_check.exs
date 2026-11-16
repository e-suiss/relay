defmodule Relay.Repo.Migrations.ValidateCategoryDefaultRouteCheck do
  use Ecto.Migration

  # OP-57
  # WF-14
  def up do
    execute("ALTER TABLE relay.categories VALIDATE CONSTRAINT categories_default_route_check")
  end

  def down, do: :ok
end
