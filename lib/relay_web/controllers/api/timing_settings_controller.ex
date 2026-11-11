defmodule RelayWeb.Api.TimingSettingsController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.TimingSettings
  alias RelayWeb.Api.Work

  # WF-58
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params), do: Work.answer(conn, TimingSettings.get(conn.assigns.scope))

  # WF-42
  # WF-58
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> TimingSettings.put(scope, body, actor) end)
  end
end
