defmodule RelayWeb.Api.SubscriberTokenController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Transport
  alias RelayWeb.Auth.Access

  # E-24
  # E-93
  # API-45
  # API-79 (2)
  # TN-25
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    proof = [proof: proof(conn), method: conn.method, url: Transport.request_url(conn)]
    audiences = Access.subscriber_audiences()

    case Relay.Access.exchange_subscriber_token(conn.assigns.body, audiences, proof) do
      {:ok, body} -> Response.json(conn, 200, body)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp proof(conn) do
    case get_req_header(conn, "dpop") do
      [proof] -> proof
      _none_or_many -> nil
    end
  end
end
