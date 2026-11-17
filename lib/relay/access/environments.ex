defmodule Relay.Access.Environments do
  @moduledoc """
  The Access environments of an Access tenant (E-108, E-103), for the check of a message's `accessenvironment`: the `id` of every entry of the tenant snapshot's `environments` list (or of its earlier `realms` list), read through `Relay.Access.Realms.snapshot/1`. They are kept for five minutes in `Relay.Access.Cache`; an environment the cached list does not name reads the snapshot again, at most once every 30 seconds per tenant. A tenant Access does not know is `:unknown`; an Access that cannot answer is `service_unavailable`.
  """

  alias Relay.Access.Cache
  alias Relay.Access.Realms

  @keep_ms 300_000
  @again_ms 30_000

  # E-108
  # E-103
  @doc "Whether `environment` is one of the Access environments of `access_tenant`: `{:ok, true | false}`, `{:ok, :unknown}` for a tenant Access does not know."
  @spec member(String.t(), String.t()) ::
          {:ok, boolean() | :unknown} | {:error, Relay.Error.t()}
  def member(access_tenant, environment)
      when is_binary(access_tenant) and is_binary(environment) do
    case cached(access_tenant) do
      {:ok, :unknown} -> {:ok, :unknown}
      {:ok, ids} -> listed(ids, access_tenant, environment)
      {:error, error} -> {:error, error}
    end
  end

  defp listed(ids, access_tenant, environment) do
    if environment in ids, do: {:ok, true}, else: again(access_tenant, environment)
  end

  defp cached(access_tenant) do
    case Cache.fetch({:access_environments, access_tenant}) do
      {:ok, ids} -> {:ok, ids}
      :miss -> read(access_tenant)
    end
  end

  defp again(access_tenant, environment) do
    if Cache.claim({:access_environments_again, access_tenant}, @again_ms) do
      case read(access_tenant) do
        {:ok, ids} when is_list(ids) -> {:ok, environment in ids}
        other -> other
      end
    else
      {:ok, false}
    end
  end

  defp read(access_tenant) do
    case Realms.snapshot(access_tenant) do
      {:ok, snapshot} -> keep(access_tenant, ids(snapshot))
      {:error, :not_found} -> keep(access_tenant, :unknown)
      {:error, _error} -> {:error, unavailable()}
    end
  end

  defp keep(access_tenant, value) do
    :ok = Cache.put({:access_environments, access_tenant}, value, @keep_ms)
    {:ok, value}
  end

  # E-103
  @doc "The environment identifiers a tenant snapshot names."
  @spec ids(map()) :: [String.t()]
  def ids(%{} = snapshot) do
    entries = snapshot["environments"] || snapshot["realms"] || []

    for %{"id" => id} <- List.wrap(entries), is_binary(id), do: String.downcase(id)
  end

  defp unavailable do
    message = "the Access environments could not be read"
    Relay.Error.new(:service_unavailable, message, %{retry_after: 30})
  end
end
