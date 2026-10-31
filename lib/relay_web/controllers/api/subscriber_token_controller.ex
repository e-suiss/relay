defmodule RelayWeb.Api.SubscriberTokenController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias RelayWeb.Api.Response
  alias RelayWeb.Auth.Access

  # E-24
  # API-45
  # API-79 (2)
  # TN-25
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    audiences = Access.subscriber_audiences()

    case Relay.Access.exchange_subscriber_token(conn.assigns.body, audiences) do
      {:ok, body} -> Response.json(conn, 200, body)
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
