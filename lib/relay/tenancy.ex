defmodule Relay.Tenancy do
  @moduledoc """
  Tenants, sub-tenants, environments, identities and the kill switch. Other contexts use only the functions of this module.

  Blind indexes and field encryption take their keys from the key provider configured as `:key_provider` in the `:relay` application environment, or from the `:key_provider` option.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.Tenancy.BlindIndex
  alias Relay.Tenancy.Context
  alias Relay.Tenancy.FieldCipher
  alias Relay.Tenancy.KeyProvider
  alias Relay.Tenancy.Settings
  alias Relay.Tenancy.Store

  @type option :: {:key_provider, module()}

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

  @doc "Encrypts a personal field under the data key of its subject and retention class."
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
  @doc "Creates a tenant mapped from an Access tenant; see `Relay.Tenancy.Store.tenant_create/2`."
  @spec create_tenant(map(), Actor.t()) ::
          {:created | :exists | :conflict | :region_mismatch, Relay.Id.t() | nil}
  defdelegate create_tenant(attrs, actor), to: Store, as: :tenant_create

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
  @doc "Updates the tenant defaults; the region is not updatable."
  @spec update_tenant_defaults(Scope.t(), map(), Actor.t()) ::
          {:ok, {atom(), integer() | nil}} | {:error, term()}
  def update_tenant_defaults(scope, change, actor) do
    within(scope, fn _status ->
      Store.tenant_update_defaults(change, change.expected_version, change.record_digest, actor)
    end)
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
  @doc "Sets or clears a stored setting at tenant level or, with `:subtenant_id`, at sub-tenant level."
  @spec put_setting(Scope.t(), map(), Actor.t()) ::
          {:ok, {atom(), integer() | nil}} | {:error, term()}
  def put_setting(scope, change, actor) do
    within(scope, fn _status ->
      Store.setting_set(
        Map.get(change, :subtenant_id),
        change.key,
        change.value,
        Map.get(change, :expected_version),
        change.record_digest,
        actor
      )
    end)
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

  # TN-65
  @doc "Registers the tenant's blind index key reference."
  @spec register_blind_index_key(Scope.t(), map(), Actor.t()) :: {:ok, atom()} | {:error, term()}
  def register_blind_index_key(scope, attrs, actor) do
    within(scope, fn _status ->
      Store.blind_index_key_register(attrs.id, attrs.hsm_ref, attrs.record_digest, actor)
    end)
  end

  defp provider(opts),
    do:
      Keyword.get_lazy(opts, :key_provider, fn ->
        Application.fetch_env!(:relay, :key_provider)
      end)
end
