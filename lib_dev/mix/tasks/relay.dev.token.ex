defmodule Mix.Tasks.Relay.Dev.Token do
  @shortdoc "Prints a server API token of the sample test plane API client"
  @moduledoc "Prints a DPoP-bound token of the sample API client that `mix relay.dev.seed` registers, signed by the local Access stand-in and valid for one hour (`RelayDev.Seed.token/1`); `mix relay.dev.proof` prints the proof each request carries with it. `--okp-x X` binds the token to the Ed25519 DPoP key whose unpadded base64url public key is `X` instead, for an SDK that signs its own proofs. It only reads the configuration, so it runs next to a running node."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [okp_x: :string])
    Mix.Task.run("app.config")
    Mix.shell().info(RelayDev.Seed.token(opts))
  end
end
