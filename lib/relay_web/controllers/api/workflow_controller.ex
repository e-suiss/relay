defmodule RelayWeb.Api.WorkflowController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Workflows
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @key ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  # API-56
  # API-69
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Workflows.list(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-1
  # WF-5
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> Workflows.create(scope, body, actor) end)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"workflow_key" => key}) do
    case key(key) do
      {:ok, key} -> Work.answer(conn, Workflows.get(conn.assigns.scope, key))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-5
  # T-59 (7)
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, %{"workflow_key" => key}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with_key(conn, key, :required, fn key, expected ->
      work = fn _status -> Workflows.replace(scope, key, body, expected, actor) end
      Work.idempotent(conn, work)
    end)
  end

  # WF-6
  # T-59 (7)
  @spec publish(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def publish(conn, %{"workflow_key" => key}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)
    note = (conn.assigns.body || %{})["note"]

    with_key(conn, key, :required, fn key, expected ->
      work = fn _status -> Workflows.publish(scope, key, expected, note, actor) end
      Work.idempotent(conn, work)
    end)
  end

  # API-56
  # WF-6
  @spec versions(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def versions(conn, %{"workflow_key" => key}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, key} <- key(key),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Workflows.versions(scope, key, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-6
  @spec version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def version(conn, %{"workflow_key" => key, "version" => number}) do
    with {:ok, key} <- key(key),
         {:ok, number} <- number(number) do
      Work.answer(conn, Workflows.version(conn.assigns.scope, key, number))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-6
  @spec promote(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def promote(conn, %{"workflow_key" => key, "version" => number}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    with {:ok, key} <- key(key),
         {:ok, number} <- number(number) do
      Work.idempotent(conn, fn _status -> Workflows.promote(scope, key, number, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp with_key(conn, key, precondition, fun) do
    with {:ok, key} <- key(key),
         {:ok, expected} <- Work.if_match(conn, precondition) do
      fun.(key, expected)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp key(key) do
    if Regex.match?(@key, key) and byte_size(key) <= 100,
      do: {:ok, key},
      else: {:error, Workflows.workflow_not_found()}
  end

  defp number(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 1 -> {:ok, n}
      _ -> {:error, Workflows.version_not_found()}
    end
  end
end
