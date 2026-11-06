defmodule RelayWeb.Api.WhatsappWebhookController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.WhatsappWebhooks
  alias RelayWeb.Api.Response

  # CH-60
  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  @spec verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify(conn, %{"provider_account_id" => account} = params) do
    case WhatsappWebhooks.verify(account, params) do
      {:ok, challenge} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, challenge)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # CH-60
  # T-40
  # sobelow_skip ["XSS.SendResp"]
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"provider_account_id" => account}) do
    case WhatsappWebhooks.accept(account, conn.assigns.raw_body, conn.req_headers) do
      :ok -> send_resp(conn, 200, "")
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
