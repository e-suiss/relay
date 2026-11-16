defmodule RelayWeb.Api.WebhookSourceController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.WebhookSources
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # WH-68
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, state} <- WebhookSources.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, WebhookSources.list(scope, state, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-68
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> WebhookSources.create(scope, body, actor) end)
  end

  # WH-68
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"webhook_source_id" => id}) do
    case id(id) do
      {:ok, id} -> Work.answer(conn, WebhookSources.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-68
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"webhook_source_id" => id}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case id(id) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status -> WebhookSources.archive(scope, id, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp id(text), do: Work.path_id(text, "whs", :webhook_source_not_found)
end
