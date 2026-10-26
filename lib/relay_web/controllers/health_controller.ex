defmodule RelayWeb.HealthController do
  @moduledoc false

  use RelayWeb, :controller

  # T-63
  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params), do: json(conn, %{status: "ok"})

  # TN-38
  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    case Relay.Platform.readiness() do
      :ok ->
        if Relay.Tenancy.KillSwitch.ready?(),
          do: json(conn, %{status: "ok"}),
          else: conn |> put_status(:service_unavailable) |> json(%{status: :kill_switch_unknown})

      {:error, %Relay.Error{code: code}} ->
        conn |> put_status(:service_unavailable) |> json(%{status: code})
    end
  end
end
