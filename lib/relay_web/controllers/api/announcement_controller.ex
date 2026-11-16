defmodule RelayWeb.Api.AnnouncementController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Announcements
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # IN-3
  # API-35
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> Announcements.create(scope, body, actor) end)
  end

  # IN-3
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"announcement_id" => text}) do
    case Work.path_id(text, "ann", :inbox_announcement_not_found) do
      {:ok, id} -> Work.answer(conn, Announcements.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # IN-3
  # IN-16
  @spec retract(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def retract(conn, %{"announcement_id" => text}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case Work.path_id(text, "ann", :inbox_announcement_not_found) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status -> Announcements.retract(scope, id, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end
end
