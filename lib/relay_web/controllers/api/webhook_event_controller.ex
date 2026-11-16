defmodule RelayWeb.Api.WebhookEventController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.WebhookEvents
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # WH-45 (2)
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, filters} <- WebhookEvents.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, WebhookEvents.list(scope, filters, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
