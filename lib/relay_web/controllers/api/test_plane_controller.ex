defmodule RelayWeb.Api.TestPlaneController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Queries
  alias Relay.Api.TestPlane
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # X-43
  @spec seeds(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def seeds(conn, _params), do: Work.answer(conn, TestPlane.list(conn.assigns.scope))

  # X-43
  @spec reset(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset(conn, _params) do
    scope = conn.assigns.scope
    Work.idempotent(conn, fn _status -> TestPlane.reset(scope) end)
  end

  # X-52
  # X-26
  @spec inbox(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def inbox(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Queries.test_inbox(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
