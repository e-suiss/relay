defmodule RelayWeb.Api.PushContentController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.PushContent
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # CH-33
  # IN-38
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"delivery_id" => text}) do
    %{scope: scope, principal: principal} = conn.assigns

    case Work.path_id(text, "dlv", :delivery_not_found) do
      {:ok, id} -> Work.answer(conn, PushContent.get(scope, principal.subscriber_id, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
