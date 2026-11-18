defmodule RelayWeb.Api.ImportController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Imports
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # OP-96
  # OP-55
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    %{scope: scope, raw_body: content} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, query} <- Imports.query(params),
         {:ok, prepared} <- Imports.prepare(scope, query, content) do
      Work.idempotent(conn, fn _status -> Imports.create(scope, prepared, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # OP-96
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    text = Map.get(params, "import_id", "")

    case Work.path_id(text, Imports.prefix(), :import_not_found) do
      {:ok, id} -> Work.answer(conn, Imports.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
