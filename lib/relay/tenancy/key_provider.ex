defmodule Relay.Tenancy.KeyProvider do
  @moduledoc """
  Key provider port. Blind index keys and data keys live outside the database, in the PKCS#11 key store reached through the Port program; this behaviour is the only way the core obtains them. Blind index keys never leave the key store, so the provider returns the HMACs, not the keys; data keys are returned wrapped in `Relay.Redacted`. `Relay.Tenancy.Keyring` is the production implementation.
  """

  @typedoc """
  Scope of a field: the tenant environment, the subject (or `nil` for a field under a tenant data key), the retention class, and the table and column that store it. A field under a tenant data key also names the key in `:key_id`.
  """
  @type data_key_scope :: %{
          required(:tenant_id) => Relay.Id.t(),
          required(:environment) => Relay.Environment.t(),
          required(:subject_id) => Relay.Id.t() | nil,
          required(:retention_class) => Relay.RetentionClass.t(),
          required(:table) => String.t(),
          required(:column) => String.t(),
          optional(:key_id) => Relay.Id.t()
        }

  @typedoc "Scope of a blind index: what is indexed, in which tenant environment."
  @type index_scope :: %{
          tenant_id: Relay.Id.t(),
          environment: Relay.Environment.t(),
          purpose: String.t()
        }

  @typedoc "Identifier of a blind index key (`blind_index_keys.id`)."
  @type version :: Relay.Id.t()

  @doc "Computes HMAC-SHA256 of `message` under every readable blind index key of a scope inside the key store: the active key first, then a key being rotated in."
  @callback blind_index_macs(index_scope(), Relay.Redacted.t()) ::
              {:ok, [{version(), <<_::256>>}]} | {:error, Relay.Error.t()}

  @doc "Returns the 32-byte data key of a field scope, or an error if it does not exist, is restricted under a statutory retention, or was destroyed."
  @callback data_key(data_key_scope()) :: {:ok, Relay.Redacted.t()} | {:error, Relay.Error.t()}
end
