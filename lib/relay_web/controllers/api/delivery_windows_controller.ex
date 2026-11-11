defmodule RelayWeb.Api.DeliveryWindowsController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.DeliveryWindows
  alias RelayWeb.Api.Work

  # DS-18
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params), do: Work.answer(conn, DeliveryWindows.get(conn.assigns.scope))

  # DS-18
  # DS-46
  # DS-50
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.spanning(conn, fn -> DeliveryWindows.replace(scope, body, actor) end)
  end
end
