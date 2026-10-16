defmodule Relay.Tenancy.KeyProvider do
  @moduledoc """
  Key provider port. Blind index keys and data keys live outside the database, in the PKCS#11 key store reached through the Port program; this behaviour is the only way the core obtains them. Keys are returned wrapped in `Relay.Redacted`.
  """

  @typedoc "Scope of a data key: one key per subject and retention class in a tenant environment."
  @type data_key_scope :: %{
          tenant_id: Relay.Id.t(),
          environment: Relay.Environment.t(),
          subject_id: Relay.Id.t(),
          retention_class: Relay.RetentionClass.t()
        }

  @typedoc "Scope of a blind index: what is indexed, in which tenant environment."
  @type index_scope :: %{
          tenant_id: Relay.Id.t(),
          environment: Relay.Environment.t(),
          purpose: String.t()
        }

  @type version :: pos_integer()

  @doc "Returns the readable blind index keys of a scope, the current key first and previous keys still being rotated out after it."
  @callback blind_index_keys(index_scope()) ::
              {:ok, [{version(), Relay.Redacted.t()}, ...]} | {:error, Relay.Error.t()}

  @doc "Returns the 32-byte data key of a scope, or an error if it does not exist or was destroyed."
  @callback data_key(data_key_scope()) :: {:ok, Relay.Redacted.t()} | {:error, Relay.Error.t()}
end
