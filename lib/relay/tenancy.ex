defmodule Relay.Tenancy do
  @moduledoc """
  Tenants, sub-tenants, environments, identities and the kill switch. Other contexts use only the functions of this module.

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
  @doc "Creates a tenant mapped from an Access tenant after validating its time zone and locale and replacing them with their canonical forms; see `Relay.Tenancy.Store.tenant_create/2`."
  @spec create_tenant(map(), Actor.t()) ::
          {:created | :exists | :conflict | :region_mismatch, Relay.Id.t() | nil}
          | {:error, Relay.Error.t()}
  def create_tenant(attrs, actor) do
    with {:ok, attrs} <- Defaults.canonical(attrs, [:default_timezone, :default_locale]),
         do: Store.tenant_create(attrs, actor)
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

  @doc "Creates a recipient with its profile data key."
  @spec create_recipient(Scope.t(), map()) ::
          {:ok, {atom(), Relay.Id.t() | nil}} | {:error, term()}
  def create_recipient(scope, attrs),
    do: within(scope, fn _status -> Store.recipient_create(attrs) end)

  # TN-27
  @doc "Registers a wrapped tenant key."
  @spec register_tenant_key(Scope.t(), map(), Actor.t()) :: {:ok, atom()} | {:error, term()}
  def register_tenant_key(scope, attrs, actor) do
    within(scope, fn _status ->
      Store.tenant_key_register(attrs, attrs.record_digest, actor)
    end)
  end

  # TN-27
  # TN-65 (1)
  @doc "Generates a tenant key, wraps it under the region KEK `:kek_label` inside the key store and registers it; `attrs` carries `:id`, `:purpose` (`:data` or `:dek_wrap`), `:kek_label` and `:record_digest`."
  @spec provision_tenant_key(Scope.t(), map(), Actor.t()) :: {:ok, atom()} | {:error, term()}
  def provision_tenant_key(scope, attrs, actor) do
    with {:ok, generated} <-
           Keyring.generate_tenant_key(scope, attrs.id, attrs.purpose, attrs.kek_label) do
      register_tenant_key(scope, Map.merge(attrs, generated), actor)
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

  # TN-65
  @doc "Registers the tenant's blind index key reference."
  @spec register_blind_index_key(Scope.t(), map(), Actor.t()) :: {:ok, atom()} | {:error, term()}
  def register_blind_index_key(scope, attrs, actor) do
    within(scope, fn _status ->
      Store.blind_index_key_register(attrs.id, attrs.hsm_ref, attrs.record_digest, actor)
    end)
  end

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
