defmodule RelayWeb.Api.WebhookConsumerController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.WebhookConsumers
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # WH-2
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, state} <- WebhookConsumers.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, WebhookConsumers.list(scope, state, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-2
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> WebhookConsumers.create(scope, body, actor) end)
  end

  # WH-2
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"webhook_consumer_id" => id}) do
    case id(id) do
      {:ok, id} -> Work.answer(conn, WebhookConsumers.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-2
  # T-59 (7)
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"webhook_consumer_id" => id}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, id} <- id(id),
         {:ok, expected} <- Work.if_match(conn, :optional) do
      work = fn _status -> WebhookConsumers.update(scope, id, body, expected, actor) end
      Work.idempotent(conn, work)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-2
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"webhook_consumer_id" => id}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case id(id) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status -> WebhookConsumers.archive(scope, id, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp id(text), do: Work.path_id(text, "whc", :webhook_consumer_not_found)
end
