defmodule Relay.Tenancy.KeyProvisioning do
  @moduledoc """
  Tenant creation with its keys, from a key plan. After the tenant row exists, each environment gets a `data` and a `dek_wrap` key, wrapped under the region KEK inside the key store, and a blind index key generated inside the key store, where it stays. The plan names the region KEK label and, for every environment and key, the key identifier and the digest of the audit record that registers it; `Relay.Tenancy.Provisioning` builds it. A key that is already active is left as it is, so a repeated mapping event adds only what is missing. Every key store call runs before the transaction that registers its key.
  """

  alias Relay.Error
  alias Relay.Scope
  alias Relay.Tenancy.Context
  alias Relay.Tenancy.Defaults
  alias Relay.Tenancy.Keyring
  alias Relay.Tenancy.Store

  @environments [:live, :test]
  @tenant_purposes [:data, :dek_wrap]
  @purposes [:data, :dek_wrap, :blind_index]

  @type purpose :: :data | :dek_wrap | :blind_index
  @type entry :: %{id: Relay.Id.t(), record_digest: <<_::256>>}
  @type plan :: %{
          kek_label: Relay.Keys.label(),
          keys: %{{Relay.Environment.t(), purpose()} => entry()}
        }

  @doc "The environments and key purposes a plan names an entry for."
  @spec slots() :: [{Relay.Environment.t(), purpose()}]
  def slots,
    do: for(environment <- @environments, purpose <- @purposes, do: {environment, purpose})

  # TN-1
  # TN-2
  # TN-65 (6)
  # TN-67 (1)
  # TN-68 (2)
  @doc "Validates and canonicalises the time zone and locale, writes the tenant row (`Relay.Tenancy.Store.tenant_create/2`) and, when the tenant is created or already exists, provisions its missing keys from `key_plan`, called with the tenant's identifier. The plan for the requested identifier is checked before the row is written."
  @spec create(map(), (Relay.Id.t() -> plan()), Relay.Actor.t()) ::
          {:created | :exists | :conflict | :region_mismatch, Relay.Id.t() | nil}
          | {:error, Error.t()}
  def create(%{id: <<_::128>> = id} = attrs, key_plan, actor) when is_function(key_plan, 1) do
    with {:ok, plan} <- check(key_plan.(id)),
         {:ok, attrs} <- Defaults.canonical(attrs, [:default_timezone, :default_locale]),
         do: with_keys(Store.tenant_create(attrs, actor), id, plan, key_plan, actor)
  end

  def create(_attrs, _key_plan, _actor),
    do: {:error, Error.new(:invalid_argument, "a tenant needs an identifier and a key plan")}

  defp with_keys({result, id}, id, plan, _key_plan, actor) when result in [:created, :exists] do
    with :ok <- provision(id, plan, actor), do: {result, id}
  end

  defp with_keys({:exists, <<_::128>> = existing}, _id, _plan, key_plan, actor) do
    with {:ok, plan} <- check(key_plan.(existing)),
         :ok <- provision(existing, plan, actor),
         do: {:exists, existing}
  end

  defp with_keys(other, _id, _plan, _key_plan, _actor), do: other

  # TN-67 (1)
  # TN-27
  # TN-65 (2)
  @doc "Provisions the missing tenant keys and blind index keys of both environments of a tenant from a key plan."
  @spec provision(Relay.Id.t(), plan(), Relay.Actor.t()) :: :ok | {:error, Error.t()}
  def provision(<<_::128>> = tenant_id, plan, actor) do
    with {:ok, plan} <- check(plan),
         do: provision_environments(@environments, tenant_id, plan, actor)
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

  defp check(%{kek_label: label, keys: keys} = plan)
       when is_binary(label) and label != "" and is_map(keys) do
    if Enum.all?(slots(), &entry?(Map.get(keys, &1))),
      do: {:ok, plan},
      else: invalid_plan()
  end

  defp check(_plan), do: invalid_plan()

  defp entry?(%{id: <<_::128>>, record_digest: <<_::256>>}), do: true
  defp entry?(_entry), do: false

  defp invalid_plan, do: {:error, Error.new(:invalid_argument, "not a tenant key plan")}

  defp provision_environments([], _tenant_id, _plan, _actor), do: :ok

  defp provision_environments([environment | rest], tenant_id, plan, actor) do
    with :ok <- provision_scope(Scope.new!(tenant_id, environment), plan, actor),
         do: provision_environments(rest, tenant_id, plan, actor)
  end

  defp provision_scope(scope, plan, actor) do
    with {:ok, active} <- Relay.Tenancy.active_key_purposes(scope),
         :ok <- tenant_keys(scope, @tenant_purposes -- active, plan, actor) do
      if :blind_index in active, do: :ok, else: blind_index_key(scope, plan, actor)
    end
  end

  defp tenant_keys(_scope, [], _plan, _actor), do: :ok

  defp tenant_keys(scope, [purpose | rest], plan, actor) do
    %{id: id, record_digest: digest} = plan.keys[{scope.environment, purpose}]
    attrs = %{id: id, purpose: purpose, kek_label: plan.kek_label, record_digest: digest}

    with {:ok, generated} <-
           Keyring.generate_tenant_key(scope, id, purpose, plan.kek_label),
         {:ok, _registered} <-
           registered(
             Context.within(scope, fn _status ->
               Store.tenant_key_register(Map.merge(attrs, generated), digest, actor)
             end)
           ),
         do: tenant_keys(scope, rest, plan, actor)
  end

  defp blind_index_key(scope, plan, actor) do
    %{id: id, record_digest: digest} = plan.keys[{scope.environment, :blind_index}]
    label = blind_index_label(scope, id)

    with :ok <- Relay.Keys.generate_key(:hmac_sha256, label, id),
         {:ok, _registered} <-
           registered(
             Context.within(scope, fn _status ->
               Store.blind_index_key_register(id, Relay.Keys.uri(label), digest, actor)
             end)
           ),
         do: :ok
  end

  defp registered({:ok, result}) when result in [:created, :exists, :active_exists],
    do: {:ok, result}

  defp registered({:error, %Error{} = error}), do: {:error, error}

  defp registered(_other),
    do: {:error, Error.new(:database_error, "tenant key registration failed")}
end
