defmodule Relay.Tenancy.Provisioning do
  @moduledoc """
  Tenant creation with its keys. After the tenant row exists, each environment gets a `data` and a `dek_wrap` key, wrapped under the region KEK inside the key store (`Relay.Tenancy.provision_tenant_key/3`), and a blind index key generated inside the key store, where it stays; the region KEK label is installation configuration (`Relay.Keys.kek_label/0`). A key that is already active is left as it is, so a repeated mapping event adds only what is missing. Every key store call runs before the transaction that registers its key, so none of these functions may run inside another transaction.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Audit, Relay.Tenancy], exports: []

  alias Relay.Actor
  alias Relay.Error
  alias Relay.Scope

  @environments [:live, :test]
  @tenant_purposes [:data, :dek_wrap]

  # TN-1
  # TN-67 (1)
  @doc "Creates a tenant mapped from an Access tenant (`Relay.Tenancy.create_tenant/2`) and, when it is created or already exists, provisions its missing keys in both environments."
  @spec create_tenant(map(), Actor.t()) ::
          {:created | :exists | :conflict | :region_mismatch, Relay.Id.t() | nil}
          | {:error, Error.t()}
  def create_tenant(attrs, %Actor{} = actor) do
    case Relay.Tenancy.create_tenant(attrs, actor) do
      {result, <<_::128>> = id} when result in [:created, :exists] ->
        with :ok <- provision(id, actor), do: {result, id}

      other ->
        other
    end
  end

  # TN-67 (1)
  # TN-27
  # TN-65 (2)
  @doc "Provisions the missing tenant keys and blind index keys of both environments of a tenant."
  @spec provision(Relay.Id.t(), Actor.t()) :: :ok | {:error, Error.t()}
  def provision(<<_::128>> = tenant_id, %Actor{} = actor) do
    with {:ok, kek_label} <- Relay.Keys.kek_label(),
         do: provision_environments(@environments, tenant_id, kek_label, actor)
  end

  # TN-65 (2)
  @doc "The key store label of a tenant environment's blind index key."
  @spec blind_index_label(Scope.t(), Relay.Id.t()) :: Relay.Keys.label()
  def blind_index_label(%Scope{} = scope, <<_::128>> = key_id) do
    Enum.join(
      [
        "relay-bidx",
        Relay.Id.to_string(scope.tenant_id),
        Relay.Environment.dump(scope.environment),
        Relay.Id.to_string(key_id)
      ],
      "/"
    )
  end

  defp provision_environments([], _tenant_id, _kek_label, _actor), do: :ok

  defp provision_environments([environment | rest], tenant_id, kek_label, actor) do
    with :ok <- provision_scope(Scope.new!(tenant_id, environment), kek_label, actor),
         do: provision_environments(rest, tenant_id, kek_label, actor)
  end

  defp provision_scope(scope, kek_label, actor) do
    with {:ok, active} <- Relay.Tenancy.active_key_purposes(scope),
         :ok <- tenant_keys(scope, @tenant_purposes -- active, kek_label, actor) do
      if :blind_index in active, do: :ok, else: blind_index_key(scope, actor)
    end
  end

  defp tenant_keys(_scope, [], _kek_label, _actor), do: :ok

  defp tenant_keys(scope, [purpose | rest], kek_label, actor) do
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      purpose: purpose,
      kek_label: kek_label,
      record_digest: record_digest(scope, "tenant_key.registered", "tenant_key", id, actor)
    }

    with {:ok, _registered} <-
           registered(Relay.Tenancy.provision_tenant_key(scope, attrs, actor)),
         do: tenant_keys(scope, rest, kek_label, actor)
  end

  defp blind_index_key(scope, actor) do
    id = Relay.Id.generate()
    label = blind_index_label(scope, id)

    attrs = %{
      id: id,
      hsm_ref: Relay.Keys.uri(label),
      record_digest:
        record_digest(scope, "blind_index_key.registered", "blind_index_key", id, actor)
    }

    with :ok <- Relay.Keys.generate_key(:hmac_sha256, label, id),
         {:ok, _registered} <-
           registered(Relay.Tenancy.register_blind_index_key(scope, attrs, actor)),
         do: :ok
  end

  defp registered({:ok, result}) when result in [:created, :exists, :active_exists],
    do: {:ok, result}

  defp registered({:error, %Error{} = error}), do: {:error, error}

  defp registered(_other),
    do: {:error, Error.new(:database_error, "tenant key registration failed")}

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
