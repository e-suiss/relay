defmodule Mix.Tasks.Relay.Lint.Comments do
  @shortdoc "Rejects explanatory comments in code and configuration"
  @moduledoc "Runs `RelayDev.Lint.Comments`. Options: `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args),
    do:
      RelayDev.Lint.report!(
        "relay.lint.comments",
        RelayDev.Lint.Comments.run(RelayDev.Lint.root(args))
      )
end
