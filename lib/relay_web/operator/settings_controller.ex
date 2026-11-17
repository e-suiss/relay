defmodule RelayWeb.Operator.SettingsController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Api.Settings

  # TN-2
  # OP-19
  # DS-44
  # TN-21
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, _params) do
    %{body: body, operator_scope: scope} = conn.assigns
    stepped = if Settings.retention_change?(body), do: step_up(conn), else: {:ok, conn}

    case stepped do
      {:ok, conn} -> idempotent(conn, fn -> Settings.update(scope, body, actor(conn)) end)
      {:error, error} -> problem(conn, error)
    end
  end
end
