defmodule Mix.Tasks.Relay.Lint.Images do
  @shortdoc "Requires SHA-pinned actions, digest-pinned images and the decided local services"
  @moduledoc "Runs `RelayDev.Lint.Images`. Options: `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args),
    do:
      RelayDev.Lint.report!(
        "relay.lint.images",
        RelayDev.Lint.Images.run(RelayDev.Lint.root(args))
      )
end
