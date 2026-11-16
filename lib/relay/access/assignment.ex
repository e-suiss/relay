defmodule Relay.Access.Assignment do
  @moduledoc """
  The environment and scopes of an API client that Access registered (E-99). Access holds neither: `api_client.created` registers the client as pending in its tenant's `live` scope, and its tokens are refused with `403 auth_client_pending` until a tenant administrator assigns it. An assignment first records the environment on the registration, audited as `api_client.assigned`, and then writes the API client trace in that environment with the API-75 scopes, audited as `api_client.created` or `api_client.updated`; both raise the API client generation, so every node sees the change. Assigning again to the same environment completes a trace an interrupted assignment left unwritten and sets the scopes again; the other environment is a conflict. Once the trace exists, the Access events deferred for the unknown client are queued again.
  """

  alias Relay.Access.Clients
  alias Relay.Access.ClientStore
  alias Relay.Access.Events
  alias Relay.Actor
  alias Relay.Scope

  @tag "relay.api_client_assignment.v1"

  # E-99
  @doc "The pending API clients of a tenant, oldest first."
  @spec pending(Relay.Id.t()) :: {:ok, [map()]} | {:error, term()}
  def pending(tenant_id) do
    ClientStore.in_scope(Scope.new!(tenant_id, :live), fn _status -> ClientStore.pending() end)
  end

  # E-99
  # API-44
  # API-75
  # TN-24
  @doc "Assigns the pending Access client `access_client_id` to the environment of `scope` with `scopes`; returns its Access client id."
  @spec assign(Scope.t(), String.t(), [String.t(), ...], Actor.t()) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def assign(%Scope{} = scope, access_client_id, scopes, %Actor{} = actor) do
    environment = Relay.Environment.dump(scope.environment)
    digest = digest(access_client_id, environment, scopes)

    work = fn _status -> ClientStore.assign(access_client_id, environment, digest, actor) end

    case ClientStore.in_scope(Scope.new!(scope.tenant_id, :live), work) do
      {:ok, {result, access_tenant, generation}} when result in [:assigned, :already_assigned] ->
        announce(generation)
        trace(scope, access_client_id, access_tenant, scopes, digest, actor)

      {:ok, {:environment_conflict, _access_tenant, _generation}} ->
        {:error, conflict("the API client is assigned to the other environment")}

      {:ok, {:not_found, _access_tenant, _generation}} ->
        {:error, Relay.Error.new(:api_client_not_found, "no such pending API client")}

      {:error, error} ->
        {:error, unavailable(error)}
    end
  end

  defp trace(scope, access_client_id, access_tenant, scopes, digest, actor) do
    attrs = %{
      id: Relay.Id.generate(),
      access_client_id: access_client_id,
      subtenant_id: nil,
      scopes: scopes,
      access_event_ref: nil
    }

    work = fn _status -> ClientStore.upsert(attrs, digest, actor) end

    case ClientStore.in_scope(scope, work) do
      {:ok, {result, _id, generation}} when result in [:created, :updated] ->
        announce(generation)
        :ok = Events.requeue(access_tenant, "unknown_client")
        {:ok, access_client_id}

      {:ok, {:unchanged, _id, _generation}} ->
        {:ok, access_client_id}

      {:ok, {_revoked_or_bound, _id, _generation}} ->
        {:error, conflict("the API client cannot be assigned")}

      {:error, error} ->
        {:error, unavailable(error)}
    end
  end

  # TN-36
  defp announce(nil), do: :ok

  defp announce(generation) do
    :ok = Clients.advance(generation)
    _ = Relay.Platform.publish_signal(Clients.topic(), generation)
    :ok
  end

  defp digest(access_client_id, environment, scopes) do
    canonical = Relay.Canonical.encode!([@tag, access_client_id, environment, scopes])
    :crypto.hash(:sha256, canonical)
  end

  defp conflict(message), do: Relay.Error.new(:resource_conflict, message)

  defp unavailable(%Relay.Error{} = error), do: error
  defp unavailable(_reason), do: Relay.Error.new(:service_unavailable, "unavailable")
end
