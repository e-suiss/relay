defmodule Mix.Tasks.Relay.Dev.Token do
  @shortdoc "Prints a server API token of the sample test plane API client"
  @moduledoc "Prints a token of the sample API client that `mix relay.dev.seed` registers, signed by the local Access stand-in and valid for one hour (`RelayDev.Seed.token/1`). It only reads the configuration, so it runs next to a running node."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    Mix.shell().info(RelayDev.Seed.token(RelayDev.Access.configured_audience()))
  end
end
