defmodule Relay.Operators.Access.Unconfigured do
  @moduledoc """
  The Access adapter of a node without an Access configuration: every call fails closed with `auth_step_up_unavailable`, so no operator signs in and no sensitive operation runs.
  """

  @behaviour Relay.Operators.Access

  alias Relay.Operators.Access

  @impl Access
  def authorization_url(_params), do: {:error, Access.unavailable("Access is not configured")}

  @impl Access
  def complete(_code, _verifier, _redirect_uri, _nonce),
    do: {:error, Access.unavailable("Access is not configured")}

  @impl Access
  def verify_access_token(_token), do: {:error, Access.unavailable("Access is not configured")}

  @impl Access
  def evaluate(_request), do: {:error, Access.unavailable("Access is not configured")}
end
