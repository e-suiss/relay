defmodule RelayWeb.Api.DiscoveryController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Contract
  alias Relay.Api.Discovery
  alias RelayWeb.Api.Response

  @cache_control "public, max-age=300"
  @parameter ~r/:([a-z_]+)/

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
    routed =
      MapSet.new(Phoenix.Router.routes(RelayWeb.Router), fn %{verb: verb, path: path} ->
        {verb |> Atom.to_string() |> String.upcase(), Regex.replace(@parameter, path, "{\\1}")}
      end)

    for operation <- Contract.operations(),
        MapSet.member?(routed, {operation.method, operation.path}),
        do: operation.id
  end
end
