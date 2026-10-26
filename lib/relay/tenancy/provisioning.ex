defmodule Relay.Tenancy.Provisioning do
  @moduledoc """
  Tenant creation with its keys, the only way to create a tenant. It builds the key plan of a tenant: the region KEK label (installation configuration, `Relay.Keys.kek_label/0`) and, for each environment, a fresh identifier and the audit record digest of its `data`, `dek_wrap` and blind index key; `Relay.Tenancy` writes the tenant row and generates and registers the keys from it (`Relay.Tenancy.create_tenant/3`). A key that is already active is left as it is, so a repeated mapping event adds only what is missing. Every key store call runs before the transaction that registers its key, so none of these functions may run inside another transaction.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Audit, Relay.Tenancy], exports: []

  alias Relay.Actor
  alias Relay.Error
  alias Relay.Scope

  @targets %{
    data: {"tenant_key.registered", "tenant_key"},
    dek_wrap: {"tenant_key.registered", "tenant_key"},
    blind_index: {"blind_index_key.registered", "blind_index_key"}
  }

  # TN-1
  # TN-67 (1)
  # TN-68 (2)
  @doc "Creates a tenant mapped from an Access tenant and, when it is created or already exists, provisions its missing keys in both environments."
  @spec create_tenant(map(), Actor.t()) ::
          {:created | :exists | :conflict | :region_mismatch, Relay.Id.t() | nil}
          | {:error, Error.t()}
  def create_tenant(attrs, %Actor{} = actor) do
    with {:ok, kek_label} <- Relay.Keys.kek_label(),
         do: Relay.Tenancy.create_tenant(attrs, &plan(&1, kek_label, actor), actor)
  end

  # TN-67 (1)
  # TN-27
  # TN-65 (2)
  @doc "Provisions the missing tenant keys and blind index keys of both environments of a tenant."
  @spec provision(Relay.Id.t(), Actor.t()) :: :ok | {:error, Error.t()}
  def provision(<<_::128>> = tenant_id, %Actor{} = actor) do
    with {:ok, kek_label} <- Relay.Keys.kek_label(),
         do:
           Relay.Tenancy.provision_tenant_keys(
             tenant_id,
             plan(tenant_id, kek_label, actor),
             actor
           )
  end

  # TN-65 (2)
  @doc "The key store label of a tenant environment's blind index key."
  @spec blind_index_label(Scope.t(), Relay.Id.t()) :: Relay.Keys.label()
  defdelegate blind_index_label(scope, key_id), to: Relay.Tenancy

  defp plan(tenant_id, kek_label, actor) do
    keys =
      Map.new(Relay.Tenancy.key_plan_slots(), fn {environment, purpose} ->
        id = Relay.Id.generate()
        {action, target_type} = Map.fetch!(@targets, purpose)
        scope = Scope.new!(tenant_id, environment)

        {{environment, purpose},
         %{id: id, record_digest: record_digest(scope, action, target_type, id, actor)}}
      end)

    %{kek_label: kek_label, keys: keys}
  end

  defp record_digest(scope, action, target_type, id, actor) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: action,
      actor_kind: Atom.to_string(actor.kind),
      actor_ref: actor.ref,
      on_behalf_of_ref: actor.on_behalf_of_ref,
      access_record_ref: actor.access_record_ref,
      target_type: target_type,
      target_id: Relay.Id.to_string(id),
      reason: nil
    })
  end
end
