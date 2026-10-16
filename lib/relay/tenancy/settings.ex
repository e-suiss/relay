defmodule Relay.Tenancy.Settings do
  @moduledoc """
  Settings inheritance between a sub-tenant and its tenant: a setting the sub-tenant does not define comes from the tenant; a setting the sub-tenant defines is never overridden by the tenant. A setting is defined when its key is present. Resolution has exactly two levels, sub-tenant then tenant, because a sub-tenant has no sub-tenants.
  """

  @type settings :: %{optional(term()) => term()}
  @type source :: :subtenant | :tenant

  # TN-3
  # TN-4
  @doc "Resolves every setting; `nil` stands for a request without a sub-tenant."
  @spec resolve(settings() | nil, settings()) :: settings()
  def resolve(nil, tenant) when is_map(tenant), do: tenant

  def resolve(subtenant, tenant) when is_map(subtenant) and is_map(tenant),
    do: Map.merge(tenant, subtenant)

  @doc "Resolves one setting and names the level it came from."
  @spec fetch(settings() | nil, settings(), term()) :: {:ok, term(), source()} | :error
  def fetch(subtenant, tenant, key)
      when is_map(tenant) and (is_map(subtenant) or is_nil(subtenant)) do
    cond do
      is_map(subtenant) and is_map_key(subtenant, key) ->
        {:ok, Map.fetch!(subtenant, key), :subtenant}

      is_map_key(tenant, key) ->
        {:ok, Map.fetch!(tenant, key), :tenant}

      true ->
        :error
    end
  end
end
