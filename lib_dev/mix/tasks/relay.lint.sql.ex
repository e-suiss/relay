defmodule Mix.Tasks.Relay.Lint.Sql do
  @shortdoc "Rejects physical deletes and AT TIME ZONE in SQL and migrations"
  @moduledoc "Runs `RelayDev.Lint.Sql`. Options: `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args),
    do: RelayDev.Lint.report!("relay.lint.sql", RelayDev.Lint.Sql.run(RelayDev.Lint.root(args)))
end
