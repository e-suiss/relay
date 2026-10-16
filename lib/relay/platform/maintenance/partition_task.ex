defmodule Relay.Platform.Maintenance.PartitionTask do
  @moduledoc """
  The `partition_maintenance` singleton task. Each step pre-creates partitions up to every table's premake horizon, checks the horizon alarm, refreshes parent statistics once per UTC day, completes an interrupted detach, and detaches at most one partition whose hot retention has passed. A detached partition is handed to the archive role: its name stays in the task state under `"detached"` until the archive step removes the table. A partition DDL that hits its lock timeout is left for the next step.

  Telemetry: `[:relay, :partition, :horizon_alarm]` (page), `[:relay, :partition, :created]`, `[:relay, :partition, :deferred]`, `[:relay, :partition, :detached]`.
  """

  @behaviour Relay.Platform.Leadership

  require Logger

  alias Relay.Platform.Maintenance.EscapeHatch
  alias Relay.Platform.Maintenance.Partitions

  @every_ms 15 * 60_000

  # OP-13
  # OP-14
  # OP-15
  # OP-68
  @impl Relay.Platform.Leadership
  @doc "Runs one maintenance step."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{state: saved}) do
    saved = saved || %{}
    now = Relay.Clock.utc_now()

    with {:ok, policies} <- EscapeHatch.partition_policies(),
         {:ok, horizon} <- EscapeHatch.partition_horizon(),
         :ok <- premake(policies, horizon, now),
         {:ok, horizon} <- EscapeHatch.partition_horizon(),
         :ok <- check_horizon(policies, horizon, now),
         {:ok, analyzed} <- analyze(policies, saved["analyzed_on"], now),
         {:ok, detached} <- archive_step(Map.get(saved, "detached", [])) do
      {:ok, %{"analyzed_on" => analyzed, "detached" => detached}, @every_ms}
    end
  end

  defp premake(policies, horizon, now) do
    bounds = Map.new(horizon, &{&1.table_name, &1.furthest_bound})

    Enum.each(policies, fn policy ->
      policy
      |> Partitions.plan(Map.get(bounds, policy.table_name), now)
      |> Enum.reduce_while(:ok, fn {from, to}, :ok -> create(policy.table_name, from, to) end)
    end)
  end

  defp create(table, from, to) do
    meta = %{table: table, from: from, to: to}

    case EscapeHatch.partition_create(table, from, to) do
      {:ok, result} when result in ["created", "exists"] ->
        :telemetry.execute(
          [:relay, :partition, :created],
          %{count: 1},
          Map.put(meta, :result, result)
        )

        {:cont, :ok}

      {:ok, "lock_timeout"} ->
        :telemetry.execute([:relay, :partition, :deferred], %{count: 1}, meta)
        {:halt, :ok}

      {:ok, other} ->
        Logger.error("partition create refused", table: table, result: other)
        {:halt, :ok}

      {:error, %{code: code}} ->
        Logger.warning("partition create failed", table: table, code: code)
        {:halt, :ok}
    end
  end

  defp check_horizon(policies, horizon, now) do
    rows = Map.new(horizon, &{&1.table_name, &1})

    for policy <- policies do
      row = Map.get(rows, policy.table_name, %{furthest_bound: nil, ok: false})

      if not row.ok or Partitions.alarm?(row.furthest_bound, policy.alarm, now) do
        :telemetry.execute([:relay, :partition, :horizon_alarm], %{count: 1}, %{
          table: policy.table_name,
          furthest_bound: row.furthest_bound
        })

        Logger.error("partition horizon below alarm threshold", table: policy.table_name)
      end
    end

    :ok
  end

  defp analyze(policies, analyzed_on, now) do
    today = now |> DateTime.to_date() |> Date.to_iso8601()

    if analyzed_on == today do
      {:ok, today}
    else
      Enum.each(policies, &analyze_one(&1.table_name))
      {:ok, today}
    end
  end

  defp analyze_one(table) do
    case EscapeHatch.parent_analyze(table) do
      {:ok, _} -> :ok
      {:error, %{code: code}} -> Logger.warning("parent analyze failed", table: table, code: code)
    end
  end

  defp archive_step(handed_off) do
    with {:ok, pending} <- EscapeHatch.pending_detaches(),
         {:ok, done} <- detach_one(pending) do
      EscapeHatch.detached_partitions(Enum.uniq(handed_off ++ done))
    end
  end

  defp detach_one([%{table_name: table, partition_name: partition} | _]),
    do: detached(table, partition, EscapeHatch.finalize_detach(table, partition))

  defp detach_one([]) do
    case EscapeHatch.partitions_due_for_archive() do
      {:ok, [%{table_name: table, partition_name: partition} | _]} ->
        detached(table, partition, EscapeHatch.detach(table, partition))

      {:ok, []} ->
        {:ok, []}

      error ->
        error
    end
  end

  defp detached(table, partition, :ok) do
    :telemetry.execute([:relay, :partition, :detached], %{count: 1}, %{
      table: table,
      partition: partition
    })

    {:ok, [partition]}
  end

  defp detached(table, partition, {:error, %{code: code}}) do
    Logger.warning("partition detach deferred", table: table, partition: partition, code: code)
    {:ok, []}
  end
end
