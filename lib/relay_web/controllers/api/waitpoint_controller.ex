defmodule RelayWeb.Api.WaitpointController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Waitpoints
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # AG-46
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, filter} <- Waitpoints.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Waitpoints.list(scope, filter, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # C-72
  # AG-8
  # AG-9
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns

    case Waitpoints.prepare(scope, body, caller(conn)) do
      {:ok, prepared} ->
        Work.idempotent(conn, fn _status -> Waitpoints.create(scope, prepared) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # AG-46
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"waitpoint_id" => text}) do
    case Work.path_id(text, "wp", :waitpoint_not_found) do
      {:ok, id} -> Work.answer(conn, Waitpoints.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # C-72
  # AG-46
  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, %{"waitpoint_id" => text}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, id} <- Work.path_id(text, "wp", :waitpoint_not_found),
         {:ok, loaded} <- Waitpoints.load(scope, id) do
      Work.idempotent(conn, fn _status ->
        Waitpoints.cancel(scope, loaded, body["reason"], actor)
      end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # AG-10
  # AG-15
  @spec heartbeat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def heartbeat(conn, %{"waitpoint_id" => text}) do
    caller = caller(conn)

    with {:ok, id} <- Work.path_id(text, "wp", :waitpoint_not_found),
         {:ok, loaded} <- Waitpoints.load(conn.assigns.scope, id) do
      Work.idempotent(conn, fn _status -> Waitpoints.heartbeat(loaded, caller) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # AG-6
  defp caller(conn), do: Waitpoints.caller(conn.assigns.principal.api_client_id)
end
