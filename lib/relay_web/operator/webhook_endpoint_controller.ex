defmodule RelayWeb.Operator.WebhookEndpointController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Api.WebhookExplicitTypes

  # WH-67
  # TN-50
  @spec subscribe(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def subscribe(conn, %{"webhook_endpoint_id" => id}) do
    with %Relay.Scope{} = scope <- conn.assigns.operator_scope,
         {:ok, id} <- path_id(id, "whe", :webhook_endpoint_not_found) do
      body = conn.assigns.body
      idempotent(conn, fn -> WebhookExplicitTypes.subscribe(scope, id, body, actor(conn)) end)
    else
      nil -> problem(conn, field("/headers/relay-tenant", "required", "the tenant context"))
      {:error, error} -> problem(conn, error)
    end
  end
end
