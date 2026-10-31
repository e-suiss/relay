defmodule Relay.Api.Store do
  @moduledoc """
  Data access of the API edge: the tenant facts a request needs before its work (status, pinned API version, API rate limit settings, certificate binding) and the automatic version pin. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @edge_keys ["api.rate.burst", "api.rate.sustained", "api.mtls_required"]

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Rolls the current transaction back with `value`."
  @spec rollback(term()) :: no_return()
  def rollback(value), do: Repo.rollback(value)

  # API-52
  @doc "The tenant's pinned API version, `nil` while none is pinned."
  @spec api_version() :: String.t() | nil
  def api_version do
    case Repo.scoped_query!("SELECT api_version::text FROM relay.tenants", []).rows do
      [[version]] -> version
      [] -> nil
    end
  end

  # API-41
  # API-50
  # API-77 (4)
  @doc "The tenant's settings that the API edge reads (rate limit tiers, `api.mtls_required`) that are set, by key."
  @spec edge_settings() :: %{optional(String.t()) => term()}
  def edge_settings do
    for row <- Repo.call!("relay_fn.setting_resolve", [nil, @edge_keys]),
        not is_nil(row["value"]),
        into: %{},
        do: {row["key"], row["value"]}
  end

  # API-52
  @doc "Pins the tenant's API version; the automatic pin only takes effect while none is pinned."
  @spec api_version_pin(String.t(), boolean(), <<_::256>>, Actor.t()) ::
          :pinned | :already_pinned | :changed | :unchanged | :unsupported
  def api_version_pin(version, automatic, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_api_version_pin",
        [Date.from_iso8601!(version), automatic, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["tenant_api_version_pin"], [
      :pinned,
      :already_pinned,
      :changed,
      :unchanged,
      :unsupported
    ])
  end
end
