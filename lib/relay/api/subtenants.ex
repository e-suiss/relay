defmodule Relay.Api.Subtenants do
  @moduledoc """
  The sub-tenants of a tenant environment as Relay mirrors them from Access (TN-3, X-4): each is an Access organization of the tenant, active or archived. The console's tenant switcher lists them; they are written only by Access events, never through this API.
  """

  alias Relay.Api.Page
  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # TN-3
  # X-4
  @doc "Lists the sub-tenants of a scope, newest first."
  @spec list(Relay.Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, page, endpoint) do
    case Relay.Tenancy.list_subtenants(scope, page.cursor, page.limit) do
      {:ok, rows} ->
        position = &{&1["cursor_at"], &1["id"]}

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # TN-3
  @doc "The API view of a sub-tenant row."
  @spec view(map()) :: map()
  def view(s) do
    %{
      "object" => "subtenant",
      "id" => Views.id("stn", s["id"]),
      "access_organization_id" => s["access_organization_id"],
      "name" => s["name"],
      "state" => s["state"],
      "archived_at" => s["archived_at"],
      "created_at" => s["created_at"],
      "updated_at" => s["updated_at"]
    }
  end
end
