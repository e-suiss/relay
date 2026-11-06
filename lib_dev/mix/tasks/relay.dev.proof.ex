defmodule Mix.Tasks.Relay.Dev.Proof do
  @shortdoc "Prints a DPoP proof for one request with a token of mix relay.dev.token"
  @moduledoc "Prints the DPoP proof of the local Access stand-in's key for one request: `mix relay.dev.proof METHOD URL TOKEN`, where `TOKEN` is the output of `mix relay.dev.token` (`RelayDev.Access.proof/3`). A proof serves one request only."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run([method, url, token]) do
    Mix.Task.run("app.config")
    Mix.shell().info(RelayDev.Access.proof(method, url, token))
  end

  def run(_args), do: Mix.raise("usage: mix relay.dev.proof METHOD URL TOKEN")
end
