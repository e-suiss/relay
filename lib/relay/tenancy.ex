defmodule Relay.Tenancy do
  @moduledoc """
  Tenants, sub-tenants, environments, identities and the kill switch. Other contexts use only the functions of this module.

  Blind indexes and field encryption take their keys from the key provider configured as `:key_provider` in the `:relay` application environment, or from the `:key_provider` option.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Tenancy.BlindIndex
  alias Relay.Tenancy.FieldCipher
  alias Relay.Tenancy.KeyProvider
  alias Relay.Tenancy.Settings

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

  defp provider(opts),
    do:
      Keyword.get_lazy(opts, :key_provider, fn ->
        Application.fetch_env!(:relay, :key_provider)
      end)
end
