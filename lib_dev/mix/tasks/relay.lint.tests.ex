defmodule Mix.Tasks.Relay.Lint.Tests do
  @shortdoc "Requires quarantined tests to name an issue; --release fails on any quarantined test"
  @moduledoc "Runs `RelayDev.Lint.Tests`. Options: `--root PATH`, `--release`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [root: :string, release: :boolean])
    root = Keyword.get(opts, :root, File.cwd!())

    RelayDev.Lint.report!(
      "relay.lint.tests",
      RelayDev.Lint.Tests.run(root, release: opts[:release] || false)
    )
  end
end
