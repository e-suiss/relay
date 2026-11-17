defmodule RelayWeb.CompletionController do
  @moduledoc false

  use RelayWeb, :controller

  alias Relay.Api.WebhookSources

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

        {status, body} = WebhookSources.inbound(notification)
        json(put_status(conn, status), body)

      _too_large ->
        conn |> put_status(413) |> json(%{"error" => "payload_too_large"})
    end
  end

  # AG-42
  # AG-37
  # WH-49
  @spec task(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def task(conn, %{"tenant" => tenant, "environment" => environment} = params) do
    case Plug.Conn.read_body(conn, length: @max_bytes) do
      {:ok, raw, conn} ->
        notification = %{
          tenant: tenant,
          environment: environment,
          source: params["webhook_source_id"],
          body: raw,
          headers: conn.req_headers
        }

        {status, body} = WebhookSources.inbound_task(notification)
        json(put_status(conn, status), body)

      _too_large ->
        conn |> put_status(413) |> json(%{"error" => "payload_too_large"})
    end
  end
end
