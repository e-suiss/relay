defmodule RelayWeb.ProviderWebhookController do
  @moduledoc false

  use RelayWeb, :controller

  @max_bytes 1_048_576

  # WH-49
  # T-40
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"provider_account_id" => account}) do
    case Plug.Conn.read_body(conn, length: @max_bytes) do
      {:ok, raw, conn} ->
        conn = Plug.Conn.fetch_query_params(conn)

        request = %{
          body: raw,
          headers: conn.req_headers,
          url: url(conn),
          token: token(conn.query_params["token"])
        }

        {status, body} = Relay.Api.ProviderWebhooks.accept(account, request)
        json(put_status(conn, status), body)

      _too_large ->
        conn |> put_status(413) |> json(%{"error" => "payload_too_large"})
    end
  end

  defp url(%Plug.Conn{query_string: ""} = conn), do: RelayWeb.Endpoint.url() <> conn.request_path

  defp url(conn),
    do: RelayWeb.Endpoint.url() <> conn.request_path <> "?" <> conn.query_string

  defp token(token) when is_binary(token) and token != "", do: token
  defp token(_none), do: nil
end
