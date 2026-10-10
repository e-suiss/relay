defmodule Mix.Tasks.Relay.Catalog.Gen do
  @shortdoc "Regenerates the rule catalog from the local specification"
  @moduledoc """
  Regenerates `conformance/catalog/rules.json` from `docs/spec` and reports rules whose acceptance fields are still pending. Options: `--root PATH`, `--spec PATH`.
  """

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [root: :string, spec: :string])
    root = Keyword.get(opts, :root, File.cwd!())
    spec = Keyword.get(opts, :spec, Path.join(root, "docs/spec"))
    unless File.dir?(spec), do: Mix.raise("specification not found at #{spec}")

    rules = RelayDev.Catalog.generate(spec, RelayDev.Catalog.read(root))
    RelayDev.Catalog.write(root, rules)

    pending =
      Enum.filter(rules, &(&1["status"] == "frozen_technical" and &1["acceptance"] == "pending"))

    Mix.shell().info(
      "relay.catalog.gen: #{length(rules)} rules; #{length(pending)} frozen technical rules with pending acceptance fields (F-32)"
    )
  end
end
