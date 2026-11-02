defmodule RelayWeb.Operator.SuppressionController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Api.Suppressions

  # PC-59 (2)
  # TN-22
  @spec lift(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lift(conn, %{"suppression_id" => text}) do
    case path_id(text, "sup", :suppression_not_found) do
      {:ok, id} -> idempotent(conn, fn -> run(conn, id) end)
      {:error, error} -> problem(conn, error)
    end
  end

  defp run(conn, id) do
    lift = %{step_up_ref: step_up_ref(conn), reason: conn.assigns.body["reason"]}
    Suppressions.lift_as_operator(conn.assigns.operator_scope, id, lift, actor(conn))
  end
end
