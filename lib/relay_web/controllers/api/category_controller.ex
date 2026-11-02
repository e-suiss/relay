defmodule RelayWeb.Api.CategoryController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Categories
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @key ~r/\A[a-z][a-z0-9_]{0,63}\z/

  # PC-57 (6)
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Categories.list(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # PC-57 (1)
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> Categories.create(scope, body, actor) end)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"category_key" => key}) do
    case key(key) do
      {:ok, key} -> Work.answer(conn, Categories.get(conn.assigns.scope, key))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # PC-57 (1)
  # T-59 (7)
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"category_key" => key}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, key} <- key(key),
         {:ok, expected} <- Work.if_match(conn, :required) do
      work = fn _status -> Categories.update(scope, key, body, expected, actor) end
      Work.idempotent(conn, work)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # PC-57 (1)
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"category_key" => key}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case key(key) do
      {:ok, key} -> Work.idempotent(conn, fn _status -> Categories.archive(scope, key, actor) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # PC-57 (2)
  @spec setting(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def setting(conn, %{"category_key" => key, "subtenant_id" => subtenant}) do
    with {:ok, key} <- key(key),
         {:ok, subtenant_id} <- Work.path_id(subtenant, "stn", :subtenant_not_found) do
      Work.answer(conn, Categories.get_setting(conn.assigns.scope, key, subtenant_id))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # PC-57 (2)
  @spec put_setting(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_setting(conn, %{"category_key" => key, "subtenant_id" => subtenant}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, key} <- key(key),
         {:ok, subtenant_id} <- Work.path_id(subtenant, "stn", :subtenant_not_found) do
      Work.idempotent(conn, fn _status ->
        Categories.put_setting(scope, key, subtenant_id, body, actor)
      end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp key(key) do
    if Regex.match?(@key, key), do: {:ok, key}, else: {:error, Categories.not_found()}
  end
end
