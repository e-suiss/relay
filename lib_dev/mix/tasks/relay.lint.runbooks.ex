defmodule Mix.Tasks.Relay.Lint.Runbooks do
  @shortdoc "Checks the runbooks and the runbook link of every alert"
  @moduledoc "Runs `RelayDev.Lint.Runbooks`. Options: `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args),
    do:
      RelayDev.Lint.report!(
        "relay.lint.runbooks",
        RelayDev.Lint.Runbooks.run(RelayDev.Lint.root(args))
      )
end
