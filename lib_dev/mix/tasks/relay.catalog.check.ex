defmodule Mix.Tasks.Relay.Catalog.Check do
  @shortdoc "Checks tests against the rule catalog"
  @moduledoc "Runs `RelayDev.Catalog.check/1`. Options: `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args),
    do:
      RelayDev.Lint.report!(
        "relay.catalog.check",
        RelayDev.Catalog.check(RelayDev.Lint.root(args))
      )
end
