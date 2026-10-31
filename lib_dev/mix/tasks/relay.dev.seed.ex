defmodule Mix.Tasks.Relay.Dev.Seed do
  @shortdoc "Seeds the local database with a sample tenant, its environments and a recipient"
  @moduledoc "Runs `RelayDev.Seed.run/0` against the database of `deploy/compose.yaml`."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    case RelayDev.Seed.run() do
      {:ok, report} -> Mix.shell().info("sample data ready: " <> inspect(report))
      {:error, reason} -> Mix.raise("sample data failed: #{inspect(reason)}")
    end
  end
end
