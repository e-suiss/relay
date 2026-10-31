defmodule RelayWeb.Api.AccessEventController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias RelayWeb.Api.Response

  # E-36
  # E-70
  # E-78
  # sobelow_skip ["XSS.SendResp"]
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    request = %{
      webhook_id: header(conn, "webhook-id"),
      timestamp: header(conn, "webhook-timestamp"),
      signature: header(conn, "webhook-signature"),
      raw_body: conn.assigns.raw_body,
      envelope: conn.assigns.body
    }

    case Relay.Access.accept_event(request) do
      :ok -> send_resp(conn, 204, "")
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first("")
end
