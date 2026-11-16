defmodule RelayWeb.Api.ThrottleController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Throttles
  alias RelayWeb.Api.Work

  # WF-32
  # API-69
  @spec reset(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset(conn, %{"throttle_key" => key}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> Throttles.reset(scope, key, actor) end)
  end
end
