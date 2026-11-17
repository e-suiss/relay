defmodule RelayWeb.Api.AgentController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Agents
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # C-21
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Agents.list(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # C-21
  # E-28
  # E-29
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case Agents.prepare(scope, body) do
      {:ok, plan} -> Work.idempotent(conn, fn _status -> Agents.create(scope, plan, actor) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # C-21
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"agent_id" => agent_id}) do
    case id(agent_id) do
      {:ok, id} -> Work.answer(conn, Agents.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # C-21
  # E-28
  # T-59 (7)
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"agent_id" => agent_id}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, id} <- id(agent_id),
         {:ok, expected} <- Work.if_match(conn, :required),
         {:ok, prepared} <- Agents.prepare_update(scope, id, body) do
      Work.idempotent(conn, fn _status -> Agents.update(scope, prepared, expected, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # AG-5
  # AG-23
  # INV-47
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"agent_id" => agent_id}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    with {:ok, id} <- id(agent_id),
         {:ok, prepared} <- Agents.prepare_delete(scope, id) do
      Work.idempotent(conn, fn _status -> Agents.delete(scope, prepared, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp id(text), do: Work.path_id(text, "agt", :agent_not_found)
end
