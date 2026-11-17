defmodule RelayWeb.Api.ComplianceSettingsController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.ComplianceSettings
  alias RelayWeb.Api.Work

  # PC-40
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params), do: Work.answer(conn, ComplianceSettings.get(conn.assigns.scope))

  # PC-40
  # INV-17
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.spanning(conn, fn -> ComplianceSettings.replace(scope, body, actor) end)
  end
end
