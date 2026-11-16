defmodule RelayWeb.CompletionController do
  @moduledoc false

  use RelayWeb, :controller

  @max_bytes Relay.Limits.fetch!(["webhook", "payload_max_bytes"])

  # WH-68
  # WH-49
  # T-40
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"tenant" => tenant, "environment" => environment} = params) do
    case Plug.Conn.read_body(conn, length: @max_bytes) do
      {:ok, raw, conn} ->
        notification = %{
          tenant: tenant,
          environment: environment,
          source: params["webhook_source_id"],
          body: raw,
          headers: conn.req_headers
        }

        {status, body} = Relay.Api.WebhookSources.inbound(notification)
        json(put_status(conn, status), body)

      _too_large ->
        conn |> put_status(413) |> json(%{"error" => "payload_too_large"})
    end
  end
end
