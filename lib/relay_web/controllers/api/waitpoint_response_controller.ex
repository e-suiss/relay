defmodule RelayWeb.Api.WaitpointResponseController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.WaitpointResponses
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # AG-25
  # AG-26
  # AG-28
  # INV-31
  @spec respond(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def respond(conn, %{"waitpoint_id" => text}) do
    %{scope: scope, principal: principal, body: body} = conn.assigns

    case Work.path_id(text, "wp", :waitpoint_not_found) do
      {:ok, id} ->
        Work.answer(conn, WaitpointResponses.respond(scope, principal.subscriber_id, id, body))

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # AG-31
  # AG-35
  @spec submit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def submit(conn, _params), do: Work.answer(conn, WaitpointResponses.submit(conn.assigns.body))
end
