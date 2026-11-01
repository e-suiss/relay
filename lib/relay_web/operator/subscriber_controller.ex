defmodule RelayWeb.Operator.SubscriberController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Operators.SubscriberSuspension

  # TN-73
  # TN-22
  @spec suspend(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def suspend(conn, %{"subscriber_id" => id}),
    do: change(conn, id, &SubscriberSuspension.suspend/4)

  # TN-73
  # TN-22
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, %{"subscriber_id" => id}), do: change(conn, id, &SubscriberSuspension.resume/4)

  defp change(conn, id, write) do
    case path_id(id, "sub", :subscriber_not_found) do
      {:ok, subscriber_id} -> idempotent(conn, fn -> run(conn, subscriber_id, write) end)
      {:error, error} -> problem(conn, error)
    end
  end

  defp run(conn, subscriber_id, write) do
    scope = conn.assigns.operator_scope
    reason = conn.assigns.body["reason"]

    with {:ok, view} <- write.(scope, subscriber_id, reason, actor(conn)),
         do: {:ok, {200, json(view)}}
  end

  defp json(view) do
    %{
      "object" => "subscriber_suspension",
      "subscriber_id" => Relay.ExternalId.encode("sub", view.subscriber_id),
      "suspended" => view.suspended,
      "suspended_at" => view.suspended_at,
      "changed" => view.changed
    }
  end
end
