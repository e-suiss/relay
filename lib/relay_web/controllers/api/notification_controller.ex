defmodule RelayWeb.Api.NotificationController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Cancels
  alias Relay.Api.Queries
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    with {:ok, page} <- Work.page(conn),
         {:ok, filters} <- Queries.filters(conn.query_params) do
      %{scope: scope, operation: operation} = conn.assigns
      Work.answer(conn, Queries.notifications(scope, filters, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"notification_id" => text} = params) do
    case Work.path_id(text, "ntf", :notification_not_found) do
      {:ok, id} ->
        expand? = params["expand"] in ["deliveries", ["deliveries"]]
        Work.answer(conn, Queries.notification(conn.assigns.scope, id, expand?))

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # API-57
  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, %{"notification_id" => text}) do
    case Work.path_id(text, "ntf", :notification_not_found) do
      {:ok, id} ->
        reason = (conn.assigns.body || %{})["reason"]
        actor = Work.actor(conn)
        Work.idempotent(conn, fn _status -> Cancels.notification(id, reason, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # API-56
  @spec deliveries(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def deliveries(conn, %{"notification_id" => text}) do
    with {:ok, id} <- Work.path_id(text, "ntf", :notification_not_found),
         {:ok, page} <- Work.page(conn) do
      %{scope: scope, operation: operation} = conn.assigns
      Work.answer(conn, Queries.deliveries(scope, id, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
