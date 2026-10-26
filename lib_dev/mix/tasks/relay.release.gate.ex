defmodule Mix.Tasks.Relay.Release.Gate do
  @shortdoc "Fails while a release gate is open; run by the release workflow only"
  @moduledoc "Runs `RelayDev.Release.gate/1`. Options: `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args),
    do:
      RelayDev.Lint.report!(
        "relay.release.gate",
        RelayDev.Release.gate(RelayDev.Lint.root(args))
      )
end
