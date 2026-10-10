defmodule RelayWeb.HealthController do
  @moduledoc false

  use RelayWeb, :controller

  # T-63
  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params), do: json(conn, %{status: "ok"})

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    case Relay.Platform.readiness() do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, %Relay.Error{code: code}} ->
        conn |> put_status(:service_unavailable) |> json(%{status: code})
    end
  end
end
