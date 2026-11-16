defmodule RelayWeb.Api.EmailReportController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.EmailReports
  alias RelayWeb.Api.Work

  # CH-46
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    Work.idempotent(conn, fn _status -> EmailReports.create(scope, body) end)
  end

  # CH-46
  @spec summary(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def summary(conn, _params),
    do: Work.answer(conn, EmailReports.summary(conn.assigns.scope, conn.query_params))
end
