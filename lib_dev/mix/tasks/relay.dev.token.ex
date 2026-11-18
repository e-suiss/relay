defmodule Mix.Tasks.Relay.Dev.Token do
  @shortdoc "Prints a server API token of the sample test plane API client"
  @moduledoc "Prints a DPoP-bound token of the sample API client that `mix relay.dev.seed` registers, signed by the local Access stand-in and valid for one hour (`RelayDev.Seed.token/1`); `mix relay.dev.proof` prints the proof each request carries with it. With `--jkt THUMBPRINT` the token is bound to the key of that RFC 7638 JWK thumbprint instead, for a client that signs its own proofs. It only reads the configuration, so it runs next to a running node."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  # E-93
  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [jkt: :string])
    Mix.Task.run("app.config")
    Mix.shell().info(RelayDev.Seed.token(opts[:jkt]))
  end
end
