defmodule RelayWeb.Api.ReportController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Reports
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # DS-35
  # DS-36
  @spec deliveries(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def deliveries(conn, _params), do: report(conn, :deliveries)

  # DS-35
  @spec skips(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def skips(conn, _params), do: report(conn, :skips)

  # DS-35
  # CH-18
  @spec costs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def costs(conn, _params), do: report(conn, :costs)

  defp report(conn, kind) do
    case Reports.period(conn.query_params) do
      {:ok, period} -> Work.answer(conn, Reports.get(conn.assigns.scope, kind, period))
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
