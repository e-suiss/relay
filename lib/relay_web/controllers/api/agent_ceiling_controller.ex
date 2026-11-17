defmodule RelayWeb.Api.AgentCeilingController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.AgentCeilings
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # AG-49
  # INV-3
  # API-56
  @spec holds(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def holds(conn, %{"agent_id" => text}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, id} <- Work.path_id(text, "agt", :agent_not_found),
         {:ok, state} <- AgentCeilings.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, AgentCeilings.list(scope, id, state, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # AG-49
  # TN-21
  @spec decide(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def decide(conn, %{"agent_id" => text}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case Work.path_id(text, "agt", :agent_not_found) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status -> AgentCeilings.decide(scope, id, body, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # AG-49
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, %{"agent_id" => text}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case Work.path_id(text, "agt", :agent_not_found) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status -> AgentCeilings.resume(scope, id, body, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end
end
