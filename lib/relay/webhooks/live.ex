defmodule Relay.Webhooks.Live do
  @moduledoc """
  The webhook engine on a running node: the sealer of `Relay.Webhooks` (`config :relay, Relay.Webhooks, sealer: Module`), which keeps signing keys, HMAC secrets and operations contact addresses encrypted under the tenant's `data` key (TN-27, TN-32). A value is sealed for the table and column that store it, in the delivery log's retention class, so it opens nowhere else and destroying the tenant's data key shreds it.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Tenancy], exports: []

  alias Relay.Scope

  @type field :: {table :: String.t(), column :: String.t()}

  # TN-27
  # TN-32
  @doc "Seals `plaintext` for `field` under the scope's active `data` key. Runs outside any transaction."
  @spec seal(Scope.t(), field(), binary() | Relay.Redacted.t()) ::
          {:ok, %{ct: binary(), key_id: Relay.Id.t()}} | {:error, Relay.Error.t()}
  def seal(%Scope{} = scope, {table, column}, plaintext) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         field = field(scope, table, column, key_id),
         {:ok, ct} <- Relay.Tenancy.encrypt_field(field, plaintext) do
      {:ok, %{ct: ct, key_id: key_id}}
    end
  end

  # TN-27
  # TN-32
  @doc "Opens a value sealed by `seal/3` for the same `field` under the tenant key `key_id`; the plaintext comes back redacted. Runs outside any transaction."
  @spec open(Scope.t(), field(), Relay.Id.t(), binary()) ::
          {:ok, Relay.Redacted.t()} | {:error, Relay.Error.t()}
  def open(%Scope{} = scope, {table, column}, <<_::128>> = key_id, ct) when is_binary(ct),
    do: Relay.Tenancy.decrypt_field(field(scope, table, column, key_id), ct)

  defp field(scope, table, column, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :delivery_record,
      table: table,
      column: column,
      key_id: key_id
    }
  end
end
