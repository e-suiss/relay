defmodule Mix.Tasks.Relay.Lint.Workers do
  @shortdoc "Requires every queue worker to use the base worker"
  @moduledoc "Runs `RelayDev.Lint.Workers`. Options: `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args),
    do:
      RelayDev.Lint.report!(
        "relay.lint.workers",
        RelayDev.Lint.Workers.run(RelayDev.Lint.root(args))
      )
end
