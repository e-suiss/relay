defmodule Mix.Tasks.Relay.Lint.Deps do
  @shortdoc "Requires permissive licenses and no excluded frameworks"
  @moduledoc "Runs `RelayDev.Lint.Deps`. Options: `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args),
    do: RelayDev.Lint.report!("relay.lint.deps", RelayDev.Lint.Deps.run(RelayDev.Lint.root(args)))
end
