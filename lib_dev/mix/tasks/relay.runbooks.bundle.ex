defmodule Mix.Tasks.Relay.Runbooks.Bundle do
  @shortdoc "Builds the offline HTML copy of the runbooks"
  @moduledoc "Writes `RelayDev.RunbookBundle.build/2` to a file. Options: `--out PATH` (default `relay-runbooks.html`), `--label TEXT` (a version or commit shown in the page) and `--root PATH`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [out: :string, label: :string, root: :string])

    out = Keyword.get(opts, :out, "relay-runbooks.html")
    html = RelayDev.RunbookBundle.build(Keyword.get(opts, :root, File.cwd!()), opts[:label] || "")
    File.write!(out, html)
    Mix.shell().info("relay.runbooks.bundle: #{out}")
  end
end
