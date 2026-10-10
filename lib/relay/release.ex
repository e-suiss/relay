defmodule Relay.Release do
  @moduledoc """
  Release commands run outside the serving nodes. Schema migrations are a separate step (`bin/relay eval Relay.Release.migrate`); a node never migrates on boot.
  """

  # T-5
  @doc "Runs all pending migrations for every repository."
  @spec migrate() :: :ok
  def migrate do
    Application.load(:relay)

    for repo <- Application.fetch_env!(:relay, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end
end
