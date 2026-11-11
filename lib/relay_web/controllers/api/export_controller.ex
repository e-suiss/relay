defmodule RelayWeb.Api.ExportController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Exports
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # DS-37
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: %{endpoint: endpoint}} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Exports.list(scope, page, endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # DS-37
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> Exports.create(scope, body, actor) end)
  end

  # DS-37
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    text = Map.get(params, "export_id", "")

    case Work.path_id(text, Exports.prefix(), :export_not_found) do
      {:ok, id} -> Work.answer(conn, Exports.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
