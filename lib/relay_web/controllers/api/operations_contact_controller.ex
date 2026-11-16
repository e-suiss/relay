defmodule RelayWeb.Api.OperationsContactController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.OperationsContacts
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # WH-56
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params), do: Work.answer(conn, OperationsContacts.get(conn.assigns.scope))

  # WH-56
  # WH-48
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case OperationsContacts.prepare(scope, body) do
      {:ok, prepared} ->
        work = fn _status -> OperationsContacts.replace(scope, prepared, actor) end
        Work.idempotent(conn, work)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end
end
