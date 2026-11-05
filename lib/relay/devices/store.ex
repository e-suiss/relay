defmodule Relay.Devices.Store do
  @moduledoc """
  Data access of devices: the write paths `relay_fn.device_register`, `relay_fn.device_disable` and `relay_fn.device_sweep`, the device reads, the tenant's device limit setting, and the cross-tenant discovery of scopes with devices to sweep through `relay_ops.device_sweep_scopes`. Every function except `in_scope/2` and `sweep_scopes/3` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @select """
  SELECT d.id, d.recipient_id, d.platform, d.app, d.token_ct, d.fingerprint, d.apns_environment,
    d.permission, d.android_channels, d.locale, d.state, d.disabled_reason, d.registered_at,
    d.last_seen_at, d.deleted_at, d.created_at, d.updated_at
  FROM relay.devices d
  """

  @register [:created, :updated, :reassigned, :recipient_not_found, :key_not_found]
  @disable [:disabled, :already_disabled, :reregistered, :not_found]

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # API-67
  # CH-74
  @doc "Registers a prepared device through `relay_fn.device_register`; see `Relay.Devices.prepare/3`."
  @spec register(map(), pos_integer()) :: {atom(), Relay.Id.t() | nil}
  def register(plan, limit) do
    [row] =
      Repo.call!("relay_fn.device_register", [
        Relay.Id.generate(),
        plan.recipient_id,
        plan.platform,
        plan.app,
        plan.digests,
        plan.bidx_key_id,
        plan.token_ct,
        plan.apns_environment,
        plan.permission,
        plan.android_channels,
        plan.locale,
        plan.previous_digests,
        limit
      ])

    {Repo.code!(row["result"], @register), row["device_id"]}
  end

  # CH-11
  # CH-31
  @doc "Disables a device by identifier or by token digests through `relay_fn.device_disable`."
  @spec disable(
          Relay.Id.t() | nil,
          [binary()] | nil,
          Relay.Id.t() | nil,
          String.t(),
          DateTime.t() | nil
        ) :: {atom(), Relay.Id.t() | nil}
  def disable(device_id, digests, recipient_id, reason, failed_at) do
    [row] =
      Repo.call!("relay_fn.device_disable", [
        device_id,
        digests,
        recipient_id,
        reason,
        failed_at
      ])

    {Repo.code!(row["result"], @disable), row["device_id"]}
  end

  # CH-31
  # OP-44
  @doc "Marks stale and disables inactive devices of the scope through `relay_fn.device_sweep`, at most `limit` of them."
  @spec sweep(pos_integer(), pos_integer(), pos_integer()) :: map()
  def sweep(stale_after_s, inactive_after_s, limit) do
    [row] = Repo.call!("relay_fn.device_sweep", [stale_after_s, inactive_after_s, limit])
    row
  end

  # CH-74
  @doc "The tenant's own device limit setting (`devices.max_active`), or `nil` while it is unset."
  @spec limit_setting() :: integer() | nil
  def limit_setting do
    case Repo.call!("relay_fn.setting_resolve", [nil, ["devices.max_active"]]) do
      [%{"value" => value} | _] when is_integer(value) -> value
      _other -> nil
    end
  end

  # API-67
  @doc "Reads a device, or `nil`."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(id) do
    case rows(@select <> " WHERE d.id = $1", [id]) do
      [row] -> row
      [] -> nil
    end
  end

  # API-67
  # CH-28
  @doc "The devices of a recipient that are not disabled, on the given platforms, most recently seen first."
  @spec current(Relay.Id.t(), [String.t()]) :: [map()]
  def current(recipient_id, platforms) do
    rows(
      @select <>
        " WHERE d.recipient_id = $1 AND d.state <> 'disabled' AND d.platform = ANY ($2)" <>
        " ORDER BY d.last_seen_at DESC, d.id DESC",
      [recipient_id, platforms]
    )
  end

  # T-24
  # TN-13 (4)
  @doc "Lists the scopes that have a device to mark stale or disable, through the discovery escape hatch; scopes only, no content."
  @spec sweep_scopes(pos_integer(), pos_integer(), pos_integer()) :: [{Relay.Id.t(), String.t()}]
  def sweep_scopes(stale_after_s, inactive_after_s, limit) do
    args = [stale_after_s, inactive_after_s, limit]
    rows = Repo.call_unscoped!(:device_sweep_discovery, "relay_ops.device_sweep_scopes", args)
    for row <- rows, do: {row["tenant_id"], row["environment"]}
  end

  defp rows(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
