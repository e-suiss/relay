defmodule Relay.Agents.Operations do
  @moduledoc """
  The agent operations gauges (AG-54, AG-71). Silence is not an error signal, so the alarms do not read an error counter: the missed-timer sweep counts, across every tenant and by count only, the waitpoints that are open or stalled and whose state has not changed for `x-relay-limits` `agent_operations.silent_after`, the responses of the last hour with their median response time (the mark of an automatic accept machine), and the response rate and opened volume of the last day beside those of the seven days before it. For the panel it also reports the stalled waitpoints, the share of waitpoints resolved by a responder an escalation added, the evidence levels of the responses of the last seven days and the notifications held at an agent ceiling.

  `report/1` emits `[:relay, :agents, :operations, :overview]` with the measurements of `measurements/1` and `[:relay, :agents, :operations, :evidence]` once per evidence level. The alert rules hold the thresholds; none of them pages.
  """

  alias Relay.Agents.WaitpointStore

  @silent_s Relay.Limits.seconds!(["agent_operations", "silent_after"])
  @levels ~w(channel_claim relay_session access_aas_ref)

  # AG-54
  # AG-71
  # TN-13 (4)
  @doc "Counts the waitpoints, responses and held agent notifications of every tenant at `now`, by count only, through the cross-tenant overview escape hatch."
  @spec overview(DateTime.t()) :: map()
  def overview(%DateTime{} = now), do: WaitpointStore.operations_overview(now, @silent_s)

  # AG-54
  # AG-71
  @doc "The gauges of an overview: the counts as they are, the opened volume of the seven days before the last day as a daily average, and the response rates and the escalation share in whole percent (0 when there is nothing to divide by, at most 100)."
  @spec measurements(map()) :: map()
  def measurements(%{} = counts) do
    %{
      silent_waitpoints: counts["silent_waitpoints"],
      stalled_waitpoints: counts["stalled_waitpoints"],
      responses_hour: counts["responses_hour"],
      median_response_ms: counts["median_response_ms"],
      opened_day: counts["opened_day"],
      opened_daily_average: div(counts["opened_week"], 7),
      response_rate_day: percent(counts["responded_day"], counts["opened_day"]),
      response_rate_week: percent(counts["responded_week"], counts["opened_week"]),
      escalation_share: percent(counts["escalated_week"], counts["resolved_week"]),
      held_notifications: counts["held_notifications"],
      open_ceiling_events: counts["open_ceiling_events"]
    }
  end

  # AG-54
  # AG-49
  @doc "The waitpoint figures of one tenant environment at `now`, in its own read transaction; see `Relay.Agents.WaitpointStore.scope_stats/2`. A waitpoint is silent after `x-relay-limits` `agent_operations.silent_after`."
  @spec scope_stats(Relay.Scope.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def scope_stats(%Relay.Scope{} = scope, %DateTime{} = now) do
    WaitpointStore.in_scope(scope, fn _status -> WaitpointStore.scope_stats(now, @silent_s) end)
  end

  defp percent(_part, 0), do: 0
  defp percent(part, whole), do: min(div(part * 100, whole), 100)

  # AG-54
  # AG-71
  @doc "Emits the agent operations gauges from the counts of `overview/1`."
  @spec report(map()) :: :ok
  def report(%{} = counts) do
    :telemetry.execute([:relay, :agents, :operations, :overview], measurements(counts), %{})

    for level <- @levels do
      measurement = %{count: counts["evidence_" <> level]}
      :telemetry.execute([:relay, :agents, :operations, :evidence], measurement, %{level: level})
    end

    :ok
  end
end
