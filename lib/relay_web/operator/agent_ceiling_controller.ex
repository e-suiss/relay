defmodule RelayWeb.Operator.AgentCeilingController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Api.AgentCeilings

  # AG-49
  # TN-21
  @spec decide(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def decide(conn, %{"agent_id" => text}) do
    case path_id(text, "agt", :agent_not_found) do
      {:ok, id} -> idempotent(conn, fn -> run(conn, id) end)
      {:error, error} -> problem(conn, error)
    end
  end

  defp run(conn, id) do
    %{operator_scope: scope, body: body} = conn.assigns
    AgentCeilings.decide_as_operator(scope, id, body, actor(conn))
  end
end
