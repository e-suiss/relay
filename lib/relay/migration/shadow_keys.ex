defmodule Relay.Migration.ShadowKeys do
  @moduledoc """
  The day keys of shadow comparison data (OP-52 (5), OP-94). Every comparison is sealed under the data key of the UTC day it was first recorded on; the key is 32 random bytes wrapped under the tenant's `dek_wrap` key for the retention class `shadow` and kept in `relay.shadow_keys`. When the shadow retention period ends (14 days, from the active `retention_periods` data set) the key's wrapped form is erased and that day's comparisons can no longer be read: crypto-shred, no row is deleted. Every function reads keys in transactions of its own, so none may run inside another transaction.
  """

  alias Relay.Migration.Store
  alias Relay.Scope

  @class :shadow

  @type key :: %{id: Relay.Id.t(), data_key: Relay.Redacted.t()}

  # OP-94
  @doc "The day key of today (UTC), registered when the day has none."
  @spec today(Scope.t()) :: {:ok, key()} | {:error, term()}
  def today(%Scope{} = scope) do
    day = DateTime.to_date(Relay.Clock.utc_now())

    case Store.in_scope(scope, fn _status -> Store.shadow_key(day) end) do
      {:ok, %{"state" => "active"} = row} -> open(scope, row)
      {:ok, nil} -> create(scope, day)
      {:ok, _destroyed} -> {:error, :key_destroyed}
      {:error, reason} -> {:error, reason}
    end
  end

  # OP-94
  @doc "The day key with this identifier; a destroyed key is `{:error, :key_destroyed}`."
  @spec fetch(Scope.t(), Relay.Id.t()) :: {:ok, key()} | {:error, term()}
  def fetch(%Scope{} = scope, key_id) do
    case Store.in_scope(scope, fn _status -> Store.shadow_key_by_id(key_id) end) do
      {:ok, %{"state" => "active"} = row} -> open(scope, row)
      {:ok, nil} -> {:error, :key_not_found}
      {:ok, _destroyed} -> {:error, :key_destroyed}
      {:error, reason} -> {:error, reason}
    end
  end

  # OP-94
  @doc "Seals a side of a comparison under a day key."
  @spec seal(Scope.t(), key(), String.t(), map()) :: {:ok, binary()} | {:error, term()}
  def seal(%Scope{} = scope, %{id: id, data_key: data_key}, column, side) when is_map(side) do
    Relay.Tenancy.encrypt_field(field(scope, id, column), Jason.encode!(side), data_key: data_key)
  end

  # OP-94
  @doc "Opens a sealed side of a comparison; `nil` and an unreadable side are `nil`."
  @spec unseal(Scope.t(), key(), String.t(), binary() | nil) :: map() | nil
  def unseal(_scope, _key, _column, nil), do: nil

  def unseal(%Scope{} = scope, %{id: id, data_key: data_key}, column, ct) when is_binary(ct) do
    with {:ok, plain} <-
           Relay.Tenancy.decrypt_field(field(scope, id, column), ct, data_key: data_key),
         {:ok, %{} = side} <- Jason.decode(Relay.Redacted.expose(plain)) do
      side
    else
      _unreadable -> nil
    end
  end

  defp create(scope, day) do
    id = Relay.Id.generate()

    with {:ok, wrap_id} <- Relay.Tenancy.active_tenant_key(scope, :dek_wrap),
         {:ok, %{wrapped_dek: wrapped, data_key: data_key}} <-
           Relay.Tenancy.generate_subject_key(scope, wrap_id, id, @class),
         {:ok, result} <-
           Store.in_scope(scope, fn _status ->
             Store.shadow_key_create(id, day, wrapped, wrap_id)
           end) do
      case result do
        {:created, ^id} -> {:ok, %{id: id, data_key: data_key}}
        {:exists, other} -> fetch(scope, other)
      end
    end
  end

  defp open(scope, row) do
    with {:ok, data_key} <-
           Relay.Tenancy.open_subject_key(
             scope,
             row["id"],
             @class,
             row["wrapped_dek"],
             row["wrapping_key_id"]
           ),
         do: {:ok, %{id: row["id"], data_key: data_key}}
  end

  defp field(scope, key_id, column) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: key_id,
      retention_class: @class,
      table: "shadow_comparisons",
      column: column
    }
  end
end
