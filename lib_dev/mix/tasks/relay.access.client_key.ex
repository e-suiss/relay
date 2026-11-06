defmodule Mix.Tasks.Relay.Access.ClientKey do
  @shortdoc "Prints the public JWK of Relay's Access client key"
  @moduledoc "Prints the public JWK of Relay's Access client key from the local key store, to register it with Relay's client in Access (`[[products]] client_key`, E-100); `Relay.Access.Client.print_client_key/0` does the same in a release."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    Relay.Access.Client.print_client_key()
  end
end
