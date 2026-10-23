defmodule RelayWeb.MetricsController do
  @moduledoc false

  use RelayWeb, :controller

  # OP-32
  # OP-69
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4", "utf-8")
    |> send_resp(200, RelayWeb.Telemetry.prometheus())
  end
end
