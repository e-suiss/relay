defmodule RelayWeb.Api.RealtimeOriginsController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.RealtimeOrigins
  alias RelayWeb.Api.Work

  # IN-54
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params), do: Work.answer(conn, RealtimeOrigins.get(conn.assigns.scope))

  # IN-54
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> RealtimeOrigins.put(scope, body, actor) end)
  end
end
