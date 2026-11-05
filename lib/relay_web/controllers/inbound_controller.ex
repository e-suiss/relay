defmodule RelayWeb.InboundController do
  @moduledoc false

  use RelayWeb, :controller

  @max_bytes 1_048_576

  # CH-62
  # WH-49
  # T-40
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"channel" => channel, "tenant" => tenant, "environment" => env} = params) do
    case Plug.Conn.read_body(conn, length: @max_bytes) do
      {:ok, raw, conn} ->
        request = %{
          channel: channel,
          tenant: tenant,
          environment: env,
          identity: params["identity"],
          raw: raw,
          headers: conn.req_headers,
          content_type: content_type(conn),
          authorization: List.first(Plug.Conn.get_req_header(conn, "authorization"))
        }

        {status, body} = Relay.Api.Messaging.inbound(request)
        json(put_status(conn, status), body)

      _too_large ->
        conn |> put_status(413) |> json(%{"error" => "payload_too_large"})
    end
  end

  defp content_type(conn) do
    with [value | _] <- Plug.Conn.get_req_header(conn, "content-type"),
         {:ok, type, subtype, _params} <- Plug.Conn.Utils.content_type(value) do
      type <> "/" <> subtype
    else
      _none -> nil
    end
  end
end
