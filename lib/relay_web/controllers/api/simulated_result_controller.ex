defmodule RelayWeb.Api.SimulatedResultController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # CH-72
  # X-26
  # API-63
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    if conn.assigns.scope.environment == :test do
      Work.answer(conn, {:ok, {200, [], view()}})
    else
      message = "the simulated results exist only in test"
      Response.problem(conn, Relay.Error.new(:auth_environment_mismatch, message))
    end
  end

  defp view do
    data =
      Enum.map(Relay.Channels.simulated_results(), &Map.put(&1, "object", "simulated_result"))

    %{"object" => "list", "data" => data, "has_more" => false, "next_cursor" => nil}
  end
end
