defmodule RelayWeb.Api.SettingsController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Rules
  alias Relay.Api.Settings
  alias RelayWeb.Api.Work

  # TN-2
  # OP-19
  # DS-44
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params), do: Work.answer(conn, Settings.get(conn.assigns.scope))

  # X-12
  # X-1
  # DS-47
  @spec rules(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rules(conn, _params), do: Work.answer(conn, Rules.list())
end
