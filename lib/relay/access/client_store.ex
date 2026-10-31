defmodule Relay.Access.ClientStore do
  @moduledoc """
  Data access of the API client traces (`relay.api_clients`, API-41 … API-44, TN-24) and of the Access ↔ Relay mapping. A token names its Access tenant and client before any tenant context exists, so the resolution and the generation counter go through `relay_ops` escape hatches; every write runs in the client's own tenant scope.
  """

  alias Relay.Actor
  alias Relay.Repo

  @find "SELECT tenant_id, environment, id, status, subtenant_id FROM relay.api_clients WHERE access_client_id = $1"
  @subtenant "SELECT tenant_id, environment, id, name, state FROM relay.subtenants WHERE access_organization_id = $1"
  @subtenant_state "SELECT tenant_id, environment, state FROM relay.subtenants WHERE id = $1"
  @overview "SELECT tenant_id, environment, id, access_client_id, status, scopes::text[], last_used_at, created_at FROM relay.api_clients ORDER BY created_at, id"
  @upserted [
    :created,
    :updated,
    :unchanged,
    :revoked_terminal,
    :subtenant_not_found,
    :subtenant_changed
  ]

  @type tenant :: %{id: Relay.Id.t(), status: String.t(), platform: String.t() | nil}
  @type subtenant :: %{id: Relay.Id.t(), name: String.t(), state: String.t()}
  @type resolved :: %{
          tenant_id: Relay.Id.t(),
          environment: String.t(),
          api_client_id: Relay.Id.t(),
          subtenant_id: Relay.Id.t() | nil,
          scopes: [String.t()],
          status: String.t(),
          tenant_status: String.t(),
          generation: non_neg_integer()
        }

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # API-71
  # TN-36
  @doc "Resolves an Access client of an Access tenant to its Relay trace, across tenants."
  @spec resolve(String.t(), String.t()) :: [resolved()]
  def resolve(access_tenant_id, access_client_id) do
    rows =
      Repo.call_unscoped!(:api_client_resolve, "relay_ops.api_client_resolve", [
        access_tenant_id,
        access_client_id
      ])

    for row <- rows do
      %{
        tenant_id: row["tenant_id"],
        environment: row["environment"],
        api_client_id: row["api_client_id"],
        subtenant_id: row["subtenant_id"],
        scopes: row["scopes"],
        status: row["status"],
        tenant_status: row["tenant_status"],
        generation: row["generation"]
      }
    end
  end

  # TN-36
  @doc "The installation's API client generation."
  @spec generation() :: non_neg_integer()
  def generation do
    [row] = Repo.call_unscoped!(:api_client_resolve, "relay_ops.api_client_generation", [])
    row["api_client_generation"]
  end

  # TN-1
  # TN-6
  @doc "The Relay tenant mapped from an Access tenant: its identifier, status and platform product."
  @spec tenant(String.t()) :: tenant() | nil
  def tenant(access_tenant) do
    rows = Repo.call_unscoped!(:access_event_intake, "relay_ops.tenant_lookup", [access_tenant])

    case rows do
      [row] -> %{id: row["tenant_id"], status: row["status"], platform: row["platform_product"]}
      [] -> nil
    end
  end

  # API-44
  @doc "Reads the trace of an Access client in the established scope."
  @spec find(String.t()) :: map() | nil
  def find(access_client_id) do
    case Repo.scoped_query!(@find, [access_client_id]).rows do
      [[_tenant, _environment, id, status, subtenant_id]] ->
        %{id: id, status: status, subtenant_id: subtenant_id}

      [] ->
        nil
    end
  end

  # TN-6
  @doc "Reads the sub-tenant mapped from an Access organization in the established scope."
  @spec subtenant(String.t()) :: subtenant() | nil
  def subtenant(access_organization_id) do
    case Repo.scoped_query!(@subtenant, [access_organization_id]).rows do
      [[_tenant, _environment, id, name, state]] -> %{id: id, name: name, state: state}
      [] -> nil
    end
  end

  # API-25
  @doc "The state of a sub-tenant in the established scope, `nil` when it does not exist."
  @spec subtenant_state(Relay.Id.t()) :: String.t() | nil
  def subtenant_state(id) do
    case Repo.scoped_query!(@subtenant_state, [id]).rows do
      [[_tenant, _environment, state]] -> state
      [] -> nil
    end
  end

  # API-44
  # TN-24
  @doc "Creates or updates the trace of an Access client in the established scope."
  @spec upsert(map(), <<_::256>>, Actor.t()) ::
          {atom(), Relay.Id.t() | nil, non_neg_integer() | nil}
  def upsert(attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.api_client_upsert",
        [
          attrs.id,
          attrs.access_client_id,
          attrs.subtenant_id,
          attrs.scopes,
          attrs.access_event_ref,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], @upserted), row["api_client_id"], row["generation"]}
  end

  # API-44
  # TN-24
  @doc "Changes the status of an Access client's trace in the established scope."
  @spec set_status(String.t(), String.t(), String.t(), <<_::256>>, Actor.t()) ::
          {:changed | :unchanged | :invalid_transition | :not_found, non_neg_integer() | nil}
  def set_status(access_client_id, status, event_ref, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.api_client_set_status",
        [access_client_id, status, event_ref, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:changed, :unchanged, :invalid_transition, :not_found]),
     row["generation"]}
  end

  # API-44
  @doc "Records the last use of an API client, at most once a minute."
  @spec touch(Relay.Id.t(), :inet.ip_address() | nil) :: :touched | :throttled | :not_found
  def touch(api_client_id, ip) do
    inet = if ip, do: %Postgrex.INET{address: ip}
    [row] = Repo.call!("relay_fn.api_client_touch", [api_client_id, inet])
    Repo.code!(row["api_client_touch"], [:touched, :throttled, :not_found])
  end

  # API-44
  # API-77 (1)
  # API-77 (2)
  @doc "Lists the API client traces of the established scope."
  @spec list() :: [map()]
  def list do
    rows = Repo.scoped_query!(@overview, []).rows

    for [_tenant, _environment, id, client, status, scopes, last_used_at, created_at] <- rows do
      %{
        id: id,
        access_client_id: client,
        status: status,
        scopes: scopes,
        last_used_at: last_used_at,
        created_at: created_at
      }
    end
  end
end
