defmodule RelayWeb.Api.DiscoveryController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Discovery
  alias RelayWeb.Api.Response

  @cache_control "public, max-age=300"

  # E-81
  @spec configuration(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def configuration(conn, _params) do
    document = Discovery.configuration(Response.base_url(), served())

    conn
    |> put_resp_header("cache-control", @cache_control)
    |> Response.json(200, document)
  end

  # E-89
  @spec jwks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def jwks(conn, _params) do
    conn
    |> put_resp_header("cache-control", @cache_control)
    |> Response.json(200, Discovery.jwks())
  end

  defp served do
    for %{private: %{relay_operation: id}} <- RelayWeb.Router.__routes__(), do: id
  end
end
