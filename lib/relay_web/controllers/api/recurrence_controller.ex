defmodule RelayWeb.Api.RecurrenceController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Recurrences
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # WF-48
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: %{endpoint: endpoint}} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Recurrences.list(scope, page, endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-48
  # WF-61
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case Recurrences.prepare(scope, body) do
      {:ok, prepared} ->
        Work.idempotent(conn, fn _status -> Recurrences.create(scope, prepared, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WF-48
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    case id(params) do
      {:ok, id} -> Work.answer(conn, Recurrences.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-49
  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, params) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    with {:ok, id} <- id(params),
         {:ok, subscriber_id} <- Recurrences.prepare_cancel(scope, id) do
      Work.idempotent(conn, fn _status -> Recurrences.cancel(scope, id, subscriber_id, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp id(params) do
    text = Map.get(params, "recurrence_id", "")
    Work.path_id(text, Recurrences.prefix(), :recurrence_not_found)
  end
end
