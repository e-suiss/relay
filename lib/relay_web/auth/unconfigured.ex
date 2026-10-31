defmodule RelayWeb.Auth.Unconfigured do
  @moduledoc """
  The verifier of a node without an Access token verifier: every credential fails closed with `service_unavailable`, so no request is served unauthenticated.
  """

  @behaviour RelayWeb.Auth

  @impl RelayWeb.Auth
  def verify(_token, _context),
    do: {:error, Relay.Error.new(:service_unavailable, "no token verifier is configured")}
end
