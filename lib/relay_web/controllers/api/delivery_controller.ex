defmodule RelayWeb.Api.DeliveryController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Queries
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # DS-15
  @spec history(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def history(conn, %{"delivery_id" => text}) do
    case Work.path_id(text, "dlv", :delivery_not_found) do
      {:ok, id} -> Work.answer(conn, Queries.history(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
