defmodule RelayWeb.Operator.TakedownController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Api.Takedowns

  # TN-60
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    with {:ok, scope} <- tenant(conn),
         {:ok, limit, after_id} <- page_params(conn),
         {:ok, rows} <- Takedowns.list(scope, after_id, limit + 1) do
      page(conn, rows, limit, &Takedowns.view/1)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  # TN-60
  # TN-21
  # TN-47
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    actor = actor(conn, installation: true)

    case tenant(conn) do
      {:ok, scope} ->
        idempotent(conn, fn -> Takedowns.take_down(scope, conn.assigns.body, actor) end)

      {:error, error} ->
        problem(conn, error)
    end
  end

  # TN-60
  # TN-21
  # TN-47
  @spec lift(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lift(conn, %{"takedown_id" => text}) do
    reason = conn.assigns.body["reason"]
    actor = actor(conn, installation: true)

    with {:ok, scope} <- tenant(conn),
         {:ok, id} <- path_id(text, "tkd", :takedown_not_found) do
      idempotent(conn, fn -> Takedowns.lift(scope, id, reason, actor) end)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  defp tenant(conn) do
    case conn.assigns.operator_scope do
      %Relay.Scope{} = scope ->
        {:ok, scope}

      nil ->
        detail = "Relay-Tenant and Relay-Environment"

        {:error,
         Relay.Error.new(:validation_failed, "the tenant context headers are invalid", %{
           errors: [%{pointer: "/headers/relay-tenant", code: "required", detail: detail}]
         })}
    end
  end
end
