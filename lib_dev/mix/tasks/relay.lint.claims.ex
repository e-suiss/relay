defmodule Mix.Tasks.Relay.Lint.Claims do
  @shortdoc "Rejects forbidden delivery and compliance claims"
  @moduledoc "Runs `RelayDev.Lint.Claims`. Options: `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args),
    do:
      RelayDev.Lint.report!(
        "relay.lint.claims",
        RelayDev.Lint.Claims.run(RelayDev.Lint.root(args))
      )
end
