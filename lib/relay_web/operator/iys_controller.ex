defmodule RelayWeb.Operator.IysController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Api.Iys

  # PC-32
  # PC-33
  # OP-42
  @spec sync(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sync(conn, _params) do
    with {:ok, scope} <- tenant(conn),
         {:ok, body} <- Iys.sync(scope) do
      reply(conn, 200, body)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  # PC-34
  # TN-47
  @spec retry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def retry(conn, %{"upload_id" => text}) do
    reason = conn.assigns.body["reason"]
    actor = actor(conn)

    with {:ok, scope} <- tenant(conn),
         {:ok, id} <- path_id(text, "iyu", :iys_upload_not_found) do
      idempotent(conn, fn -> Iys.retry(scope, id, reason, actor) end)
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
