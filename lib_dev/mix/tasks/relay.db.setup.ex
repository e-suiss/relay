defmodule Mix.Tasks.Relay.Db.Setup do
  @shortdoc "Creates, bootstraps and migrates the development or test database"
  @moduledoc "Runs `RelayDev.Database.setup/1`. Options: `--drop` drops the database first, `--quiet` hides migration logs."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [drop: :boolean, quiet: :boolean])
    Mix.Task.run("app.config")

    RelayDev.Database.setup(
      drop: Keyword.get(opts, :drop, false),
      log: if(Keyword.get(opts, :quiet, false), do: false, else: :info)
    )
  end
end
