defmodule RelayWeb.Operator.IysCredentialController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Api.IysCredentials

  # PC-29
  # TN-21
  # TN-26
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    case conn.assigns.operator_scope do
      %Relay.Scope{} = scope ->
        work = fn -> IysCredentials.register(scope, conn.assigns.body, actor(conn)) end
        idempotent(conn, work)

      nil ->
        problem(conn, tenant_required())
    end
  end

  defp tenant_required do
    Relay.Error.new(:validation_failed, "the tenant context headers are invalid", %{
      errors: [
        %{
          pointer: "/headers/relay-tenant",
          code: "required",
          detail: "Relay-Tenant and Relay-Environment"
        }
      ]
    })
  end
end
