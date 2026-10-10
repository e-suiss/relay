defmodule Mix.Tasks.Relay.Bench.Reductions do
  @shortdoc "Fails when a pure core function needs more reductions than its baseline"
  @moduledoc "Measures `RelayDev.BenchCases` against `bench/reductions.baseline.json`. Options: `--update` rewrites the baseline."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  alias RelayDev.Reductions

  @baseline "bench/reductions.baseline.json"

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [update: :boolean])
    Mix.Task.run("app.config")

    measured =
      Map.new(RelayDev.BenchCases.all(), fn {name, fun} -> {name, Reductions.measure(fun)} end)

    if opts[:update] do
      File.write!(@baseline, Jason.encode!(measured, pretty: true) <> "\n")
      Mix.shell().info("relay.bench.reductions: baseline updated")
    else
      baseline = @baseline |> File.read!() |> Jason.decode!()

      case Reductions.compare(measured, baseline) do
        [] -> Mix.shell().info("relay.bench.reductions: ok")
        problems -> Mix.raise("relay.bench.reductions: " <> Enum.join(problems, "; "))
      end
    end
  end
end
