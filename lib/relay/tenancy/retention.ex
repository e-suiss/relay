defmodule Relay.Tenancy.Retention do
  @moduledoc """
  The `retention_sweep` singleton task. Retention never deletes a row: when a period ends the data key is destroyed and the rows stay, unreadable, until their partition moves to the cold archive. Each step finds, across all tenants and by identifiers only, the receipt day keys whose day lies seven or more days back and the subject data keys whose retention period (from the active `retention_periods` data set) has ended, and destroys each one in its own tenant-scoped transaction. A key under legal hold, or one the database does not yet allow to destroy, is left for a later step.

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
  @actor %Relay.Actor{kind: :system, ref: "relay:retention_sweep", on_behalf_of_ref: "relay"}

  # OP-16
  # OP-17
  @impl Relay.Platform.Leadership
  @doc "Destroys one batch of due receipt day keys and subject data keys; runs again soon while batches are full and progressing, hourly otherwise."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(_context) do
    today = DateTime.to_date(Relay.Clock.utc_now())

    with {:ok, receipts} <- EscapeHatch.receipt_day_keys_due(Date.add(today, -7), @batch),
         {:ok, subjects} <- EscapeHatch.retention_due(@batch) do
      receipt_counts =
        receipts
        |> Enum.filter(&Erasure.receipt_key_due?(&1.valid_day, today))
        |> Enum.map(&destroy_receipt_key/1)
        |> Enum.frequencies()

      subject_counts = subjects |> Enum.map(&retire_subject_key/1) |> Enum.frequencies()

      progressing =
        Map.get(receipt_counts, :destroyed, 0) + Map.get(subject_counts, :retired, 0) > 0

      full = length(receipts) == @batch or length(subjects) == @batch
      delay = if full and progressing, do: 1_000, else: @every_ms

      {:ok,
       %{
         "swept_on" => Date.to_iso8601(today),
         "results" => stringify(receipt_counts),
         "subject_results" => stringify(subject_counts)
       }, delay}
    end
  end

  defp destroy_receipt_key(key) do
    key
    |> scope()
    |> Erasure.destroy_tenant_key(key.key_id, "retention_end", @actor)
    |> outcome([:destroyed, :already_destroyed], "receipt_day")
  end

  defp retire_subject_key(key) do
    key
    |> scope()
    |> Erasure.retire_subject_key(key.subject_key_id, @actor)
    |> outcome([:retired, :already_destroyed], key.retention_class)
  end

  defp outcome({:ok, result}, done, purpose) do
    event = if result in done, do: :destroyed, else: :skipped

    :telemetry.execute([:relay, :retention, event], %{count: 1}, %{
      purpose: purpose,
      result: result
    })

    result
  end

  defp outcome({:error, %{code: code}}, _done, purpose) do
    Logger.warning("retention key destruction failed", purpose: purpose, code: code)
    :error
  end

  defp scope(key), do: Relay.Scope.new!(key.tenant_id, key.environment)

  defp stringify(counts), do: Map.new(counts, fn {k, v} -> {Atom.to_string(k), v} end)
end
