defmodule Relay.Tenancy do
  @moduledoc """
  Tenants, sub-tenants, environments, identities and the kill switch. Other contexts use only the functions of this module. A tenant is created only together with its keys (`create_tenant/3`, through `Relay.Tenancy.Provisioning`); no function writes a tenant row without them.

  Blind indexes and field encryption take their keys from the key provider configured as `:key_provider` in the `:relay` application environment (`Relay.Tenancy.Keyring`), or from the `:key_provider` option.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.Tenancy.BlindIndex
  alias Relay.Tenancy.Context
  alias Relay.Tenancy.Defaults
  alias Relay.Tenancy.FieldCipher
  alias Relay.Tenancy.KeyCache
  alias Relay.Tenancy.KeyProvider
  alias Relay.Tenancy.KeyProvisioning
  alias Relay.Tenancy.Keyring
  alias Relay.Tenancy.SettingKeys
  alias Relay.Tenancy.Settings
  alias Relay.Tenancy.Store

  @type option :: {:key_provider, module()} | {:data_key, Relay.Redacted.t()}

  # TN-4
  @doc "Resolves sub-tenant settings over tenant settings; see `Relay.Tenancy.Settings.resolve/2`."
  @spec resolve_settings(Settings.settings() | nil, Settings.settings()) :: Settings.settings()
  defdelegate resolve_settings(subtenant, tenant), to: Settings, as: :resolve

  @doc "Resolves one setting and names its level; see `Relay.Tenancy.Settings.fetch/3`."
  @spec fetch_setting(Settings.settings() | nil, Settings.settings(), term()) ::
          {:ok, term(), Settings.source()} | :error
  defdelegate fetch_setting(subtenant, tenant, key), to: Settings, as: :fetch

  # TN-33
  @doc "Computes a blind index under every readable key, the current key first."
  @spec blind_index_digests(KeyProvider.index_scope(), binary() | Relay.Redacted.t(), [option()]) ::
          {:ok, [BlindIndex.entry(), ...]} | {:error, Relay.Error.t()}
  def blind_index_digests(scope, value, opts \\ []),
    do: BlindIndex.digests(provider(opts), scope, value)

  @doc "Computes a blind index under the current key."
  @spec blind_index(KeyProvider.index_scope(), binary() | Relay.Redacted.t(), [option()]) ::
          {:ok, BlindIndex.entry()} | {:error, Relay.Error.t()}
  def blind_index(scope, value, opts \\ []), do: BlindIndex.current(provider(opts), scope, value)

  @doc "Returns true if a stored blind index entry equals one of the computed entries."
  @spec blind_index_match?([BlindIndex.entry()], BlindIndex.entry()) :: boolean()
  defdelegate blind_index_match?(computed, stored), to: BlindIndex, as: :matches?

  @doc "Encrypts a personal field under the data key of its subject and retention class; with `:data_key` under that key, before its record exists."
  @spec encrypt_field(KeyProvider.data_key_scope(), binary() | Relay.Redacted.t(), [option()]) ::
          {:ok, binary()} | {:error, Relay.Error.t()}
  def encrypt_field(scope, plaintext, opts \\ []),
    do: FieldCipher.encrypt(provider(opts), scope, plaintext)

  @doc "Decrypts a personal field written for `scope`; the plaintext is returned redacted."
  @spec decrypt_field(KeyProvider.data_key_scope(), binary(), [option()]) ::
          {:ok, Relay.Redacted.t()} | {:error, Relay.Error.t()}
  def decrypt_field(scope, stored, opts \\ []),
    do: FieldCipher.decrypt(provider(opts), scope, stored)

  # TN-13 (2)
  # TN-13 (5)
  @doc "Runs work in a transaction scoped to a tenant environment; see `Relay.Tenancy.Context.within/3`."
  @spec within(Scope.t(), (Context.status() -> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  defdelegate within(scope, work, opts \\ []), to: Context

  # TN-10
  @doc "Returns `:ok` for an active tenant status and a `:tenant_inactive` error otherwise."
  @spec require_active(Context.status()) :: :ok | {:error, Relay.Error.t()}
  defdelegate require_active(status), to: Context

  # TN-1
  # TN-2
  # TN-65 (6)
  # TN-67 (1)
  # TN-68 (2)
  @doc "Creates the tenant mapped from an Access tenant together with its keys; see `Relay.Tenancy.KeyProvisioning.create/3`. A tenant is never created without its keys; `Relay.Tenancy.Provisioning.create_tenant/2` builds the key plan and is the way to call this."
  @spec create_tenant(map(), (Relay.Id.t() -> KeyProvisioning.plan()), Actor.t()) ::
          {:created | :exists | :conflict | :region_mismatch, Relay.Id.t() | nil}
          | {:error, Relay.Error.t()}
  defdelegate create_tenant(attrs, key_plan, actor), to: KeyProvisioning, as: :create

  # TN-67 (1)
  # TN-27
  # TN-65 (2)
  @doc "Provisions the missing keys of an existing tenant from a key plan; see `Relay.Tenancy.KeyProvisioning.provision/3`."
  @spec provision_tenant_keys(Relay.Id.t(), KeyProvisioning.plan(), Actor.t()) ::
          :ok | {:error, Relay.Error.t()}
  defdelegate provision_tenant_keys(tenant_id, plan, actor), to: KeyProvisioning, as: :provision

  @doc "The environments and key purposes a key plan names an entry for."
  @spec key_plan_slots() :: [{Relay.Environment.t(), KeyProvisioning.purpose()}]
  defdelegate key_plan_slots(), to: KeyProvisioning, as: :slots

  # TN-65 (2)
  @doc "The key store label of a tenant environment's blind index key."
  @spec blind_index_label(Scope.t(), Relay.Id.t()) :: Relay.Keys.label()
  defdelegate blind_index_label(scope, key_id), to: KeyProvisioning

  # TN-67 (1)
  @doc "Names the keys a scope already has: `:data` and `:dek_wrap` for an active tenant key of that purpose, `:blind_index` for an active or rotating blind index key."
  @spec active_key_purposes(Scope.t()) ::
          {:ok, [:data | :dek_wrap | :blind_index]} | {:error, Relay.Error.t()}
  def active_key_purposes(scope) do
    case within(scope, fn _status -> Store.active_key_purposes() end) do
      {:ok, purposes} -> {:ok, purposes}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Relay.Error.new(:database_error, "tenant key read failed")}
    end
  end

  @doc "Reads the tenant of a scope."
  @spec tenant(Scope.t()) :: {:ok, map() | nil} | {:error, term()}
  def tenant(scope), do: within(scope, fn _status -> Store.tenant() end)

  # TN-10
  @doc "Changes the tenant status; `change` carries `:status`, `:reason`, `:expected_version` and `:record_digest`."
  @spec set_tenant_status(Scope.t(), map(), Actor.t()) ::
          {:ok, {atom(), integer() | nil}} | {:error, term()}
  def set_tenant_status(scope, change, actor) do
    within(scope, fn _status ->
      Store.tenant_set_status(
        change.status,
        Map.get(change, :reason),
        change.expected_version,
        change.record_digest,
        actor
      )
    end)
  end

  # TN-2
  # TN-46
  # TN-65 (6)
  @doc "Updates the tenant defaults with an audit record; a time zone or locale is validated and canonicalised first, `nil` keeps the current value, and the region is not updatable."
  @spec update_tenant_defaults(Scope.t(), map(), Actor.t()) ::
          {:ok, {atom(), integer() | nil}} | {:error, term()}
  def update_tenant_defaults(scope, change, actor) do
    with {:ok, change} <-
           Defaults.canonical(change, [:default_timezone, :default_locale], required: false) do
      within(scope, fn _status ->
        Store.tenant_update_defaults(change, change.expected_version, change.record_digest, actor)
      end)
    end
  end

  # TN-3
  @doc "Creates or updates a sub-tenant in the scope's environment."
  @spec upsert_subtenant(Scope.t(), map(), Actor.t()) ::
          {:ok, {atom(), Relay.Id.t() | nil, integer() | nil}} | {:error, term()}
  def upsert_subtenant(scope, attrs, actor),
    do: within(scope, fn _status -> Store.subtenant_upsert(attrs, attrs.record_digest, actor) end)

  @doc "Archives a sub-tenant."
  @spec archive_subtenant(Scope.t(), Relay.Id.t(), binary(), Actor.t()) ::
          {:ok, atom()} | {:error, term()}
  def archive_subtenant(scope, subtenant_id, digest, actor),
    do: within(scope, fn _status -> Store.subtenant_archive(subtenant_id, digest, actor) end)

  # TN-4
  @doc "Sets or clears a stored setting at tenant level or, with `:subtenant_id`, at sub-tenant level. The key must be in the setting catalog and the value must pass its check (`Relay.Tenancy.SettingKeys`); `nil` clears."
  @spec put_setting(Scope.t(), map(), Actor.t()) ::
          {:ok, {atom(), integer() | nil}} | {:error, term()}
  def put_setting(scope, change, actor) do
    with {:ok, value} <- SettingKeys.cast(change.key, change.value) do
      within(scope, fn _status ->
        Store.setting_set(
          Map.get(change, :subtenant_id),
          change.key,
          value,
          Map.get(change, :expected_version),
          change.record_digest,
          actor
        )
      end)
    end
  end

  # TN-4
  @doc "Resolves stored settings for an optional sub-tenant."
  @spec resolve_stored_settings(Scope.t(), Relay.Id.t() | nil, [String.t()]) ::
          {:ok, [{String.t(), term(), atom()}]} | {:error, term()}
  def resolve_stored_settings(scope, subtenant_id, keys),
    do: within(scope, fn _status -> Store.setting_resolve(subtenant_id, keys) end)

  # C-19
  # C-20
  # TN-33
  # OP-18
  @doc "Creates a recipient: generates its `recipient_profile` data key under the tenant's active `dek_wrap` key, encrypts its external identifier under that key and indexes it under the current blind index key, then writes the recipient and its data key in one call. `attrs` carries `:id`, `:kind` and `:external_id`. The key store is called outside any transaction, so this function must not run inside one."
  @spec create_recipient(Scope.t(), map(), [option()]) ::
          {:ok, {:created | :exists | :tenant_inactive, Relay.Id.t() | nil}} | {:error, term()}
  def create_recipient(
        scope,
        %{id: <<_::128>> = id, kind: kind, external_id: external_id},
        opts \\ []
      )
      when kind in [:subscriber, :agent] do
    index_scope = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      purpose: "external_id"
    }

    field_scope = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: id,
      retention_class: :recipient_profile,
      table: "recipients",
      column: "external_id_ct"
    }

    with {:ok, wrapping_key_id} <- active_tenant_key(scope, :dek_wrap),
         {:ok, {bidx_key_id, bidx}} <- blind_index(index_scope, external_id, opts),
         {:ok, %{wrapped_dek: wrapped_dek, data_key: data_key}} <-
           Keyring.generate_subject_key(scope, wrapping_key_id, id, :recipient_profile),
         {:ok, external_id_ct} <- encrypt_field(field_scope, external_id, data_key: data_key) do
      within(scope, fn _status ->
        Store.recipient_create(%{
          id: id,
          kind: kind,
          external_id_bidx: bidx,
          bidx_key_id: bidx_key_id,
          external_id_ct: external_id_ct,
          profile_dek_id: Relay.Id.generate(),
          profile_wrapped_dek: wrapped_dek,
          wrapping_key_id: wrapping_key_id
        })
      end)
    end
  end

  # TN-27
  @doc "Returns the identifier of the scope's active tenant key of a purpose (`:data` or `:dek_wrap`)."
  @spec active_tenant_key(Scope.t(), :data | :dek_wrap) ::
          {:ok, Relay.Id.t()} | {:error, Relay.Error.t()}
  def active_tenant_key(scope, purpose) when purpose in [:data, :dek_wrap] do
    case within(scope, fn _status -> Store.active_tenant_key(Atom.to_string(purpose)) end) do
      {:ok, <<_::128>> = id} -> {:ok, id}
      {:ok, nil} -> {:error, Relay.Error.new(:data_key_not_found, "no active tenant key")}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Relay.Error.new(:database_error, "tenant key read failed")}
    end
  end

  # TN-33
  # OP-18
  @doc "Generates a subject data key for a retention class, wrapped under the tenant key `wrapping_key_id`. The wrapped form is registered with the recipient or the subject key record; the returned data key encrypts the record's first fields through the `:data_key` option."
  @spec generate_subject_key(Scope.t(), Relay.Id.t(), Relay.Id.t(), Relay.RetentionClass.t()) ::
          {:ok, %{wrapped_dek: binary(), data_key: Relay.Redacted.t()}}
          | {:error, Relay.Error.t()}
  defdelegate generate_subject_key(scope, wrapping_key_id, recipient_id, class), to: Keyring

  # TN-66 (2)
  @doc "Drops every unwrapped key cached on this node."
  @spec flush_key_cache() :: :ok
  def flush_key_cache, do: KeyCache.flush()

  # TN-66 (2)
  @doc "Supervised children of the context: the node's data key cache."
  @spec children() :: [module()]
  def children, do: [KeyCache]

  defp provider(opts) do
    case Keyword.fetch(opts, :data_key) do
      {:ok, key} ->
        {:key, key}

      :error ->
        Keyword.get_lazy(opts, :key_provider, fn ->
          Application.fetch_env!(:relay, :key_provider)
        end)
    end
  end
end
