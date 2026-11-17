defmodule RelayWeb.Api.IysController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Iys
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # PC-29
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params), do: Work.answer(conn, Iys.get(conn.assigns.scope))

  # PC-29
  # E-22
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> Iys.replace(scope, body, actor) end)
  end

  # PC-29
  @spec brands(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def brands(conn, _params), do: Work.answer(conn, Iys.brands(conn.assigns.scope))

  # PC-29
  # PC-34
  @spec test(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def test(conn, _params), do: Work.answer(conn, Iys.test(conn.assigns.scope))

  # PC-30
  # API-56
  @spec uploads(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def uploads(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, state} <- Iys.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Iys.uploads(scope, state, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
