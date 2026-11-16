defmodule Relay.Observability.Rollup do
  @moduledoc """
  The `observability_rollup` singleton task: once a minute it counts the ledger events received since its last step (at most an hour back, and 30 seconds behind the clock so that late commits are not missed) and turns the counts into telemetry. Funnel stages are `[:relay, :funnel, :stage]`, skips by rule `[:relay, :delivery, :skipped]`, conflicts and late events `[:relay, :delivery, :anomaly]`, unknown outcomes `[:relay, :delivery, :outcome]`, the provider handoff and availability SLIs `[:relay, :slo, :handoff]` and `[:relay, :slo, :availability]` against the SLO table, accepted deliveries that never reached the queue `[:relay, :funnel, :gap]` and the largest tenant share of each queue's waiting jobs `[:relay, :neighbours, :share]`. The funnel and the SLOs are counted from the ledger, never from traces. A gauge that has no row in a step is set back to zero. The window's end and the gauges it set are the task state.
  """

  @behaviour Relay.Platform.Leadership

  alias Relay.Observability.Slo
  alias Relay.Observability.Store

  @every_ms 60_000
  @lag_s 30
  @max_window_s 3_600
  @min_queued 100
  @slis %{"handoff" => :handoff, "availability" => :availability}

  # OP-33
  # OP-36
  # DS-36
  # DS-41
  # TN-62
  @impl Relay.Platform.Leadership
  @doc "Counts one window and schedules the next step a minute later."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{state: state}) do
    to = DateTime.add(Relay.Clock.utc_now(), -@lag_s, :second)
    from = from(state, to)

    with {:ok, rows} <- Store.rollup(from, to, handoff_ms()) do
      gauges = emit(rows, Map.get(state || %{}, "gauges", []))
      {:ok, %{"to" => DateTime.to_iso8601(to), "gauges" => gauges}, @every_ms}
    end
  end

  # OP-36
  @doc "The provider handoff thresholds of the SLO table in milliseconds, by message class."
  @spec handoff_ms() :: %{String.t() => pos_integer()}
  def handoff_ms, do: Map.new(Slo.classes(), &{Atom.to_string(&1), Slo.handoff_ms(&1)})

  # OP-33
  # TN-62
  @doc "Emits the telemetry of a window's rows; `previous` are the gauges set by the last step, as `[kind, label, channel, provider]`. Returns the gauges this step set."
  @spec emit([map()], [[String.t()]]) :: [[String.t()]]
  def emit(rows, previous) do
    Enum.each(rows, &emit_row/1)
    gauges = for %{"kind" => kind} = row <- rows, kind in ["gap", "queue_share"], do: key(row)

    for key <- previous, key not in gauges, do: reset(key)

    gauges
  end

  defp from(state, to) do
    earliest = DateTime.add(to, -@max_window_s, :second)

    with %{"to" => text} <- state, {:ok, at, _offset} <- DateTime.from_iso8601(text) do
      if DateTime.compare(at, earliest) == :gt, do: at, else: earliest
    else
      _none -> DateTime.add(to, -div(@every_ms, 1000), :second)
    end
  end

  defp key(row), do: [row["kind"], row["label"], row["channel"], row["provider"]]

  defp emit_row(%{"kind" => "stage"} = row),
    do: count([:relay, :funnel, :stage], row["total"], %{stage: row["label"]}, row)

  defp emit_row(%{"kind" => "skipped"} = row),
    do: count([:relay, :delivery, :skipped], row["total"], %{rule_id: row["label"]}, row)

  defp emit_row(%{"kind" => "anomaly"} = row),
    do: count([:relay, :delivery, :anomaly], row["total"], %{kind: row["label"]}, row)

  defp emit_row(%{"kind" => "outcome"} = row),
    do: count([:relay, :delivery, :outcome], row["total"], %{outcome: row["label"]}, row)

  defp emit_row(%{"kind" => kind} = row) when kind in ["handoff", "availability"] do
    event = [:relay, :slo, Map.fetch!(@slis, kind)]
    class = %{class: row["message_class"]}
    count(event, row["good"], Map.put(class, :good, true), row)
    count(event, row["total"] - row["good"], Map.put(class, :good, false), row)
  end

  defp emit_row(%{"kind" => "gap"} = row),
    do: gap(row["label"], row["channel"], row["provider"], row["total"])

  defp emit_row(%{"kind" => "queue_share"} = row) do
    share = if row["total"] >= @min_queued, do: row["good"] / row["total"], else: 0.0
    meta = %{signal: "queue_queued", queue: row["label"]}
    :telemetry.execute([:relay, :neighbours, :share], %{share: share}, meta)
  end

  defp emit_row(_row), do: :ok

  defp count(_event, 0, _meta, _row), do: :ok

  defp count(event, n, meta, row) do
    meta = Map.merge(meta, %{channel: row["channel"], provider: row["provider"]})
    :telemetry.execute(event, %{count: n}, meta)
  end

  defp reset(["gap", label, channel, provider]), do: gap(label, channel, provider, 0)

  defp reset(["queue_share", label, _channel, _provider]) do
    meta = %{signal: "queue_queued", queue: label}
    :telemetry.execute([:relay, :neighbours, :share], %{share: 0.0}, meta)
  end

  defp reset(_key), do: :ok

  defp gap(label, channel, provider, n) do
    meta = %{gap: label, channel: channel, provider: provider}
    :telemetry.execute([:relay, :funnel, :gap], %{count: n}, meta)
  end
end
