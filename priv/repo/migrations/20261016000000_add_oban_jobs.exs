defmodule Relay.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  # T-17
  def up, do: Oban.Migrations.up(version: 14, prefix: "oban")
end
