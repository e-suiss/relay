defmodule RelayWeb.Api.FallbackController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Versions
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Transport

  # API-36
  # API-8
  @spec not_found(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def not_found(conn, _params) do
    conn
    |> put_resp_header("strict-transport-security", Transport.hsts())
    |> put_resp_header("relay-version", Versions.latest())
    |> Response.problem(Relay.Error.new(:route_not_found, "no such route"))
  end
end
