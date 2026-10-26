defmodule RelayWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor and metric definitions. Metric tags come from bounded sets only; tenant, user, device, address or identifier never become a tag.

  Every stage 1 alarm is a Prometheus metric, scraped from `GET /metrics` on the internal metrics port (`RelayWeb.Metrics`) and matched by an alert rule in `deploy/observability/alerts.yaml`. An alarm that is a state is a 0/1 gauge; an alarm that is an event is the Unix time of its last occurrence (`*_timestamp_seconds`).
  """

  use Supervisor

  import Telemetry.Metrics

  @reporter :relay_metrics

  @doc false
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [
      {Peep, name: @reporter, metrics: alarm_metrics()},
      {:telemetry_poller, measurements: [], period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
  end

  # T-63
  @doc "Metric definitions exported by reporters."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("relay.repo.query.total_time", unit: {:native, :millisecond}),
      summary("relay.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ] ++ alarm_metrics()
  end

  # OP-69
  # OP-13
  # OP-63
  # OP-70
  # OP-42
  # OP-71
  # OP-3
  # OP-11
  # T-9
  # T-17
  # T-86
  @doc "The stage 1 alarm metrics."
  @spec alarm_metrics() :: [Telemetry.Metrics.t()]
  def alarm_metrics do
    [
      last_value("relay.partition.horizon_alarm.timestamp_seconds",
        event_name: [:relay, :partition, :horizon_alarm],
        measurement: &now/1,
        tags: [:table],
        description: "Last time a partitioned table's furthest bound was below the alarm horizon"
      ),
      last_value("relay.leadership.leaderless",
        event_name: [:relay, :leadership, :state],
        measurement: :leaderless,
        tags: [:task],
        description: "1 while a singleton task has had no leader for five minutes"
      ),
      last_value("relay.audit.checkpoint_overdue.timestamp_seconds",
        event_name: [:relay, :audit, :overdue],
        measurement: &now/1,
        description: "Last time an audit record was integrated after the declared interval"
      ),
      last_value("relay.audit.checkpoint_unpublished.timestamp_seconds",
        event_name: [:relay, :audit, :unpublished],
        measurement: &now/1,
        description: "Last time a signed checkpoint reached no publication target"
      ),
      last_value("relay.audit.mismatch.timestamp_seconds",
        event_name: [:relay, :audit, :mismatch],
        measurement: &now/1,
        tags: [:kind],
        description: "Last time the audit verification or read-back found a mismatch"
      ),
      last_value("relay.queue.polling",
        event_name: [:relay, :queue, :mode],
        measurement: :polling,
        tags: [:component],
        description: "1 while the job queue notifier or stager falls back to polling"
      ),
      last_value("relay.integrity.violation.timestamp_seconds",
        event_name: [:relay, :integrity, :violation],
        measurement: &now/1,
        tags: [:check, :table],
        description: "Last time the nightly integrity check found a violation"
      ),
      last_value("relay.integrity.last_run.timestamp_seconds",
        event_name: [:relay, :integrity, :run],
        measurement: &now/1,
        description: "Last time the nightly integrity check completed a run"
      ),
      last_value("relay.projection.difference.timestamp_seconds",
        event_name: [:relay, :projection, :difference],
        measurement: &now/1,
        description:
          "Last time the weekly rebuild found a projection that differs from its ledger"
      ),
      last_value("relay.postgres.query_stats_missing",
        event_name: [:relay, :postgres, :query_stats],
        measurement: :count,
        description: "1 when PostgreSQL does not preload pg_stat_statements"
      ),
      last_value("relay.valkey.eviction_policy_mismatch",
        event_name: [:relay, :valkey, :guard],
        measurement: :mismatch,
        description: "1 while Valkey runs with an eviction policy other than noeviction"
      )
    ]
  end

  # OP-32
  @doc "Renders the alarm metrics in the Prometheus text exposition format."
  @spec prometheus() :: iolist()
  def prometheus, do: @reporter |> Peep.get_all_metrics() |> Peep.Prometheus.export()

  defp now(_measurements), do: DateTime.to_unix(Relay.Clock.utc_now())
end
