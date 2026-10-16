defmodule Relay.Tenancy.Retention do
  @moduledoc """
  The `retention_sweep` singleton task. Retention never deletes a row: when a period ends the data key is destroyed and the rows stay, unreadable, until their partition moves to the cold archive. Each step finds receipt day keys whose day lies seven or more days back across all tenants (identifiers only) and destroys each one in its own tenant-scoped transaction, so that the raw provider webhook bodies of that day become unreadable. A key under legal hold, or one the database does not yet allow to destroy, is left for a later step.

  Telemetry: `[:relay, :retention, :destroyed]`, `[:relay, :retention, :skipped]`.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Platform.Maintenance, Relay.Platform.Leadership, Relay.Keys.Erasure],
    exports: []

  @behaviour Relay.Platform.Leadership

  require Logger

  alias Relay.Keys.Erasure
  alias Relay.Platform.Maintenance.EscapeHatch

  @every_ms 60 * 60_000
  @batch 500
  @actor %{kind: "system", ref: "relay:retention_sweep", on_behalf_of: "relay"}

  # OP-16
  # OP-17
  @impl Relay.Platform.Leadership
  @doc "Destroys one batch of due receipt day keys; runs again soon while batches are full, hourly otherwise."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(_context) do
    today = DateTime.to_date(Relay.Clock.utc_now())

    with {:ok, keys} <- EscapeHatch.receipt_day_keys_due(Date.add(today, -7), @batch) do
      counts =
        keys
        |> Enum.filter(&Erasure.receipt_key_due?(&1.valid_day, today))
        |> Enum.map(&destroy/1)
        |> Enum.frequencies()

      delay =
        if length(keys) == @batch and Map.get(counts, :destroyed, 0) > 0,
          do: 1_000,
          else: @every_ms

      {:ok, %{"swept_on" => Date.to_iso8601(today), "results" => stringify(counts)}, delay}
    end
  end

  defp destroy(key) do
    scope = %{tenant_id: key.tenant_id, environment: key.environment}

    case Erasure.destroy_tenant_key(scope, key.key_id, "retention_end", @actor) do
      {:ok, result} when result in [:destroyed, :already_destroyed] ->
        :telemetry.execute([:relay, :retention, :destroyed], %{count: 1}, %{
          purpose: "receipt_day"
        })

        result

      {:ok, result} ->
        :telemetry.execute([:relay, :retention, :skipped], %{count: 1}, %{reason: result})
        result

      {:error, %{code: code}} ->
        Logger.warning("receipt day key destruction failed", code: code)
        :error
    end
  end

  defp stringify(counts), do: Map.new(counts, fn {k, v} -> {Atom.to_string(k), v} end)
end
