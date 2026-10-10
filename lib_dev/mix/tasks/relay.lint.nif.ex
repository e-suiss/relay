defmodule Mix.Tasks.Relay.Lint.Nif do
  @shortdoc "Requires every native crate to be on the allowed list"
  @moduledoc "Runs `RelayDev.Lint.Nif`. Options: `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args),
    do: RelayDev.Lint.report!("relay.lint.nif", RelayDev.Lint.Nif.run(RelayDev.Lint.root(args)))
end
