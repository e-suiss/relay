defmodule Relay.Policy.IysGate.Store do
  @moduledoc """
  Data access of the default İYS gate: the tenant's region, read inside the caller's scoped transaction.
  """

  alias Relay.Repo

  @region "SELECT t.region::text FROM relay.tenants t WHERE t.id = $1"

  # PC-27
  @doc "The region of a tenant, or `nil`."
  @spec region(Relay.Id.t()) :: String.t() | nil
  def region(tenant_id) do
    case Repo.scoped_query!(@region, [tenant_id]) do
      %Postgrex.Result{rows: [[region]]} -> region
      %Postgrex.Result{rows: []} -> nil
    end
  end
end
