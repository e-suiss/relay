defmodule Mix.Tasks.Relay.Access.ServiceKey do
  @shortdoc "Prints the public JWK and RFC 7638 thumbprint of Relay's Access service key"
  @moduledoc "Prints the public JWK of Relay's Access service key from the local key store, with its RFC 7638 thumbprint as `kid`, to register it with Relay's client in Access (E-101); `Relay.Access.ServiceKey.print_service_key/0` does the same in a release."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    Relay.Access.ServiceKey.print_service_key()
  end
end
