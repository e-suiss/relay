defmodule RelayWeb.Api.RouteController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Routes
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @key ~r/\A[a-z][a-z0-9_]{0,63}\z/

  # WF-13
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Routes.list(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-13
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> Routes.create(scope, body, actor) end)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"route_key" => key}) do
    case key(key) do
      {:ok, key} -> Work.answer(conn, Routes.get(conn.assigns.scope, key))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-14
  # T-59 (7)
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, %{"route_key" => key}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, key} <- key(key),
         {:ok, expected} <- Work.if_match(conn, :required) do
      work = fn _status -> Routes.replace(scope, key, body, expected, actor) end
      Work.idempotent(conn, work)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-14
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"route_key" => key}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case key(key) do
      {:ok, key} -> Work.idempotent(conn, fn _status -> Routes.archive(scope, key, actor) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp key(key) do
    if Regex.match?(@key, key), do: {:ok, key}, else: {:error, Routes.not_found()}
  end
end
