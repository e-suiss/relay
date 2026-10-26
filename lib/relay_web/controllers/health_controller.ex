defmodule RelayWeb.HealthController do
  @moduledoc false

  use RelayWeb, :controller

  # T-63
  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params), do: json(conn, %{status: "ok"})

  # TN-38
  # CH-69
  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    case readiness() do
      :ok -> json(conn, %{status: "ok"})
      {:error, status} -> conn |> put_status(:service_unavailable) |> json(%{status: status})
    end
  end

  defp readiness do
    with :ok <- platform(),
         :ok <- kill_switch(),
         do: channel_parameters()
  end

  defp platform do
    case Relay.Platform.readiness() do
      :ok -> :ok
      {:error, %Relay.Error{code: code}} -> {:error, code}
    end
  end

  defp kill_switch do
    if Relay.Tenancy.KillSwitch.ready?(), do: :ok, else: {:error, :kill_switch_unknown}
  end

  defp channel_parameters do
    case Relay.Datasets.channel_parameters() do
      {:ok, _snapshot} -> :ok
      {:error, %Relay.Error{code: :no_active_version}} -> {:error, :channel_parameters_missing}
      {:error, %Relay.Error{code: code}} -> {:error, code}
    end
  end
end
