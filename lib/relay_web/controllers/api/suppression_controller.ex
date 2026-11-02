defmodule RelayWeb.Api.SuppressionController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Suppressions
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # PC-59 (2)
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, filters} <- Suppressions.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Suppressions.list(scope, filters, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # PC-59 (2)
  # OP-20
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case Suppressions.prepare(scope, body) do
      {:ok, prepared} ->
        Work.idempotent(conn, fn _status -> Suppressions.create(scope, prepared, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # PC-59 (2)
  @spec lift(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lift(conn, %{"suppression_id" => text}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    lift = %{lifter: "tenant", step_up_ref: nil, reason: body["reason"]}

    case Work.path_id(text, "sup", :suppression_not_found) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status -> Suppressions.lift(scope, id, lift, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end
end
