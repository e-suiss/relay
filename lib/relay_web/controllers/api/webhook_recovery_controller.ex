defmodule RelayWeb.Api.WebhookRecoveryController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.WebhookMessages
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # WH-31
  # WH-37
  # WH-48
  @spec recover(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def recover(conn, params), do: start(conn, params, "recover")

  # WH-31
  # WH-32 (3)
  # WH-48
  @spec retry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def retry(conn, params), do: start(conn, params, "retry")

  # WH-31
  # WH-33
  # WH-48
  @spec replay(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replay(conn, params), do: start(conn, params, "replay")

  # WH-31
  # WH-48
  @spec cancel_retries(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel_retries(conn, params), do: start(conn, params, "cancel_retries")

  defp start(conn, %{"webhook_endpoint_id" => id}, operation) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case id(id) do
      {:ok, id} ->
        work = fn _status -> WebhookMessages.recovery(scope, operation, id, body, actor) end
        Work.idempotent(conn, work)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-30 (2)
  # WH-37
  # API-56
  @spec missed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def missed(conn, %{"webhook_endpoint_id" => id}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, id} <- id(id),
         {:ok, filters} <- WebhookMessages.missed_filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, WebhookMessages.missed(scope, id, filters, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp id(text), do: Work.path_id(text, "whe", :webhook_endpoint_not_found)
end
