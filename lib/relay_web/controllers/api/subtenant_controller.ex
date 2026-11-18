defmodule RelayWeb.Api.SubtenantController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Subtenants
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # TN-3
  # X-4
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Subtenants.list(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
