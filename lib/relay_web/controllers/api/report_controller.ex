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

  # WF-50
  # DS-35
  @spec variants(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def variants(conn, _params), do: report(conn, :variants)

  # TP-26
  # TP-41
  @spec render_problems(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def render_problems(conn, _params), do: report(conn, :render_problems)

  # X-6
  # WF-46
  @spec fallback_timezones(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def fallback_timezones(conn, _params), do: report(conn, :fallback_zones)

  defp report(conn, kind) do
    case Reports.period(conn.query_params) do
      {:ok, period} -> Work.answer(conn, Reports.get(conn.assigns.scope, kind, period))
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
