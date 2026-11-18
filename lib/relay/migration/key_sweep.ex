defmodule Relay.Migration.KeySweep do
  @moduledoc """
  The `shadow_key_sweep` singleton task (OP-52 (5), OP-79, OP-94). Each step finds, across all tenants and by identifiers only, the shadow day keys whose day lies a full shadow retention period back (14 days, or the shorter period of the active `retention_periods` data set) and destroys each one in its own tenant-scoped transaction, audited as `shadow_key.destroyed`; the comparisons sealed under it can no longer be read and no row is deleted. Every node then drops the key from its key cache.

  Telemetry: `[:relay, :retention, :destroyed]` and `[:relay, :retention, :skipped]` with purpose `shadow_day`.
  """

  @behaviour Relay.Platform.Leadership

  require Logger

  alias Relay.Migration.Store
  alias Relay.Platform.Maintenance.EscapeHatch

  @every_ms 60 * 60_000
  @batch 500
  @actor %Relay.Actor{kind: :system, ref: "relay:shadow_key_sweep", on_behalf_of_ref: "relay"}

  # OP-52 (5)
  # OP-79
  @impl Relay.Platform.Leadership
  @doc "Destroys one batch of due shadow day keys; runs again soon while batches are full and progressing, hourly otherwise."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(_context) do
    with {:ok, keys} <- EscapeHatch.shadow_keys_due(@batch) do
      counts = keys |> Enum.map(&destroy/1) |> Enum.frequencies()
      destroyed = Map.get(counts, :destroyed, 0)
      if destroyed > 0, do: Relay.Keys.Eviction.notify()
      delay = if length(keys) == @batch and destroyed > 0, do: 1_000, else: @every_ms
      {:ok, %{"results" => Map.new(counts, fn {k, v} -> {Atom.to_string(k), v} end)}, delay}
    end
  end

  defp destroy(key) do
    scope = Relay.Scope.new!(key.tenant_id, key.environment)
    digest = digest(scope, key.key_id)

    work = fn _status -> Store.shadow_key_destroy(key.key_id, digest, @actor) end

    case Store.in_scope(scope, work) do
      {:ok, result} ->
        event = if result in [:destroyed, :already_destroyed], do: :destroyed, else: :skipped

        :telemetry.execute([:relay, :retention, event], %{count: 1}, %{
          purpose: "shadow_day",
          result: result
        })

        result

      {:error, reason} ->
        Logger.warning("shadow key destruction failed", reason: inspect(reason))
        :error
    end
  end

  defp digest(scope, key_id) do
    environment = Relay.Environment.dump(scope.environment)
    record = ["shadow_key.destroyed", {:bytes, scope.tenant_id}, environment, {:bytes, key_id}]
    :crypto.hash(:sha256, Relay.Canonical.encode!(record))
  end
end
