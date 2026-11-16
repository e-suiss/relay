defmodule Mix.Tasks.Relay.Access.PepCsr do
  @shortdoc "Prints the certificate signing request of Relay's AuthZEN PEP key"
  @moduledoc "Prints the PEM certificate signing request of Relay's PEP key from the local key store, for Access or the operator CA to issue the PEP client certificate (E-102); `Relay.Access.Pep.print_csr/0` does the same in a release."

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    Relay.Access.Pep.print_csr()
  end
end
