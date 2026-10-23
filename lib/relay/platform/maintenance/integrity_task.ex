defmodule Relay.Platform.Maintenance.IntegrityTask do
  @moduledoc """
  The `integrity_check` singleton task, run nightly: the orphan record check, the foreign key and stream key reference check and the partition horizon. Every violation is reported as `[:relay, :integrity, :violation]` and logged; a clean run is `[:relay, :integrity, :clean]`. Every completed nightly run is `[:relay, :integrity, :run]`, whose time feeds the stale check alarm. The report of the last run is saved in the task state.
  """

  @behaviour Relay.Platform.Leadership

  require Logger

  alias Relay.Platform.Maintenance.EscapeHatch

  @every_ms 24 * 60 * 60_000

  # OP-42
  # OP-71 (2)
  # TN-16
  @impl Relay.Platform.Leadership
  @doc "Runs the check once and schedules the next run a day later."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(_context) do
    with {:ok, report} <- check() do
      :telemetry.execute([:relay, :integrity, :run], %{count: 1}, %{})
      {:ok, Map.put(report, "checked_at", DateTime.to_iso8601(Relay.Clock.utc_now())), @every_ms}
    end
  end

  @doc "Runs the orphan check, the reference check and the horizon check and reports what they found."
  @spec check() :: {:ok, %{String.t() => [map()]}} | {:error, Relay.Error.t()}
  def check do
    with {:ok, orphans} <- EscapeHatch.orphan_check(),
         {:ok, references} <- EscapeHatch.reference_check(),
         {:ok, horizon} <- EscapeHatch.partition_horizon() do
      violations =
        for %{violations: n} = row <- orphans ++ references, n > 0 do
          %{"check" => row.check_name, "table" => row.table_name, "violations" => n}
        end

      short =
        for %{ok: false} = row <- horizon do
          %{"check" => "partition_horizon", "table" => row.table_name, "violations" => 1}
        end

      report(violations ++ short)
      {:ok, %{"violations" => violations ++ short}}
    end
  end

  defp report([]), do: :telemetry.execute([:relay, :integrity, :clean], %{count: 1}, %{})

  defp report(violations) do
    Enum.each(violations, fn v ->
      :telemetry.execute([:relay, :integrity, :violation], %{violations: v["violations"]}, %{
        check: v["check"],
        table: v["table"]
      })

      Logger.error("integrity check violation",
        check: v["check"],
        table: v["table"],
        violations: v["violations"]
      )
    end)
  end
end
