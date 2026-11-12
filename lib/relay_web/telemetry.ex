defmodule RelayWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor and metric definitions. Metric tags come from bounded sets only; user, device, address or identifier never become a tag, histograms never carry the tenant, and a counter carries it only as the bounded label of the busiest tenants (OP-35).

  Every alarm is a Prometheus metric, scraped from `GET /metrics` on the internal metrics port (`RelayWeb.Metrics`) and matched by an alert rule in `deploy/observability/alerts.yaml`. An alarm that is a state is a 0/1 gauge; an alarm that is an event is the Unix time of its last occurrence (`*_timestamp_seconds`).
  """

  use Supervisor

  import Telemetry.Metrics

  @reporter :relay_metrics
  @vm_samples [
    :memory_total,
    :memory_processes,
    :memory_binary,
    :memory_ets,
    :memory_atom,
    :process_count,
    :process_limit,
    :port_count,
    :port_limit,
    :atom_count,
    :atom_limit,
    :run_queue,
    :dirty_cpu_run_queue,
    :dirty_io_run_queue
  ]

  @doc false
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [
      {Peep, name: @reporter, metrics: exported_metrics()},
      {:telemetry_poller, measurements: [{Relay.Observability, :vm_sample, []}], period: 10_000}
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
    ] ++ exported_metrics()
  end

  # OP-32
  @doc "Every metric exported on `/metrics`."
  @spec exported_metrics() :: [Telemetry.Metrics.t()]
  def exported_metrics do
    alarm_metrics() ++
      policy_metrics() ++
      render_metrics() ++
      slo_metrics() ++
      delivery_metrics() ++
      operations_metrics() ++
      reconciliation_metrics() ++
      inbox_metrics() ++
      vm_metrics()
  end

  # DS-42
  # OP-35 (6)
  # OP-36
  # TN-44
  @doc "The SLI counters of the SLO table: accept and provider handoff latency within the class threshold, provider acceptance, tenant SLO violations, and the kill switch effect time."
  @spec slo_metrics() :: [Telemetry.Metrics.t()]
  def slo_metrics do
    [
      counter("relay.slo.accept.total",
        event_name: [:relay, :slo, :accept],
        tags: [:class, :good],
        description: "Accepted single events by class and whether they were within the threshold"
      ),
      sum("relay.slo.handoff.total",
        event_name: [:relay, :slo, :handoff],
        measurement: :count,
        tags: [:class, :channel, :provider, :good],
        description: "Provider handoffs by class and whether they were within the threshold"
      ),
      sum("relay.slo.availability.total",
        event_name: [:relay, :slo, :availability],
        measurement: :count,
        tags: [:class, :channel, :provider, :good],
        description: "Provider attempts by class and whether the provider accepted them"
      ),
      sum("relay.slo.tenant_violation.total",
        event_name: [:relay, :slo, :tenant_violation],
        measurement: :count,
        tags: [:channel, :severity],
        description: "Tenant SLO windows that missed their target"
      ),
      last_value("relay.kill_switch.effect.seconds",
        event_name: [:relay, :kill_switch, :effective],
        measurement: fn %{duration_ms: ms} -> ms / 1000 end,
        tags: [:platform],
        description: "Seconds from a kill switch stop to the last queued job paused"
      ),
      counter("relay.slo.kill_switch.total",
        event_name: [:relay, :slo, :kill_switch],
        tags: [:platform, :good],
        description: "Kill switches by whether they took effect within the target"
      ),
      sum("relay.kill_switch.paused.total",
        event_name: [:relay, :kill_switch, :sweep],
        measurement: :paused,
        tags: [:platform],
        description: "Queued jobs a kill switch sweep paused"
      )
    ]
  end

  # DS-24
  # DS-36
  # DS-41
  # OP-33
  # OP-37 (7)
  # CH-47
  # MD-12
  @doc "The delivery metrics that are always produced: the funnel and its gaps, skips by rule, duplicates, conflicts and late events, unknown outcomes and codes, provider event delay, clicks by kind and the extra alarm signals."
  @spec delivery_metrics() :: [Telemetry.Metrics.t()]
  def delivery_metrics do
    [
      sum("relay.funnel.total",
        event_name: [:relay, :funnel, :stage],
        measurement: :count,
        tags: [:stage, :channel, :provider],
        description: "Deliveries reaching each funnel stage, counted from the ledger"
      ),
      last_value("relay.funnel.gap",
        event_name: [:relay, :funnel, :gap],
        measurement: :count,
        tags: [:gap, :channel, :provider],
        description: "Deliveries missing between two funnel stages"
      ),
      sum("relay.delivery.skipped.total",
        event_name: [:relay, :delivery, :skipped],
        measurement: :count,
        tags: [:channel, :rule_id],
        description: "Skipped deliveries by rule"
      ),
      sum("relay.delivery.anomaly.total",
        event_name: [:relay, :delivery, :anomaly],
        measurement: :count,
        tags: [:kind, :channel, :provider],
        description: "Duplicate deliveries, conflicts and late events"
      ),
      sum("relay.delivery.outcome.total",
        event_name: [:relay, :delivery, :outcome],
        measurement: :count,
        tags: [:outcome, :channel, :provider],
        description: "Delivery outcomes, unknown_pending and unknown included"
      ),
      counter("relay.provider.unknown_code.total",
        event_name: [:relay, :channels, :unknown_code],
        tags: [:channel, :provider],
        description: "Provider codes without a mapping"
      ),
      counter("relay.provider.event.total",
        event_name: [:relay, :provider, :event],
        tags: [:channel, :provider],
        description: "Provider delivery events received"
      ),
      distribution("relay.provider.event_delay.seconds",
        event_name: [:relay, :provider, :event],
        measurement: fn %{delay_ms: ms} -> ms / 1000 end,
        tags: [:channel, :provider],
        description: "Seconds from the provider handoff to the provider's delivery event"
      ),
      sum("relay.engagement.click.total",
        event_name: [:relay, :engagement, :click],
        measurement: :count,
        tags: [:channel, :kind],
        description: "Clicks by human or likely bot"
      ),
      counter("relay.policy.quiet_hour_violation.total",
        event_name: [:relay, :policy, :quiet_hour_violation],
        tags: [:channel],
        description: "Deliveries handed off inside the recipient's quiet hours"
      ),
      counter("relay.digest.flush.total",
        event_name: [:relay, :digest, :flush],
        tags: [:result],
        description: "Digest flushes by result"
      ),
      counter("relay.campaign.overrun.total",
        event_name: [:relay, :campaign, :overrun],
        tags: [:lane],
        description: "Campaigns running longer than 1.5 times their estimate"
      ),
      counter("relay.agents.silent_wait.total",
        event_name: [:relay, :agents, :silent_wait],
        description: "Agent waits that ended without any answer"
      ),
      counter("relay.agents.message.total",
        event_name: [:relay, :agents, :message],
        tags: [:direction],
        description: "Agent messages sent and replies received"
      ),
      last_value("relay.provider.incident",
        event_name: [:relay, :provider, :incident],
        measurement: :active,
        tags: [:provider],
        description: "1 while the provider's status page reports an incident"
      )
    ]
  end

  # OP-35 (3)
  # OP-37 (1)
  # OP-37 (2)
  # IN-18
  # IN-21
  # OP-42
  @doc "The inbox counter metrics: counters the reconciliation found drifted and fixed, by source (`nightly` or `report`), and the clients' inconsistency reports by result (`consistent` or `repaired`), whose repaired share is the inconsistency rate."
  @spec inbox_metrics() :: [Telemetry.Metrics.t()]
  def inbox_metrics do
    [
      sum("relay.inbox.counter_drift.total",
        event_name: [:relay, :inbox, :counter_drift],
        measurement: :count,
        tags: [:source],
        description: "Inbox counters the reconciliation found drifted from the items and fixed"
      ),
      sum("relay.inbox.inconsistency_reports.total",
        event_name: [:relay, :inbox, :inconsistency_report],
        measurement: :count,
        tags: [:result],
        description: "Client reports of inconsistent inbox counters, by reconciliation result"
      )
    ]
  end

  # T-6
  # T-68 (3)
  # TN-62
  @doc "The operations metrics: oldest job age per lane, provider breaker state, noisy neighbour shares, jobs per tenant (busiest tenants only) and the request budget counters."
  @spec operations_metrics() :: [Telemetry.Metrics.t()]
  def operations_metrics do
    [
      last_value("relay.queue.oldest_job_age.seconds",
        event_name: [:relay, :load_shed, :delay],
        measurement: fn %{ms: ms} -> ms / 1000 end,
        tags: [:lane],
        description: "Age of the oldest job waiting in each lane"
      ),
      last_value("relay.breaker.open",
        event_name: [:relay, :breaker, :state],
        measurement: :open,
        tags: [:provider],
        description: "1 while the provider breaker is open"
      ),
      last_value("relay.noisy_neighbour.share",
        event_name: [:relay, :neighbours, :share],
        measurement: :share,
        tags: [:signal, :queue],
        description: "Largest share of one tenant or API client in the last window"
      ),
      counter("relay.jobs.processed.total",
        event_name: [:relay, :jobs, :processed],
        tags: [:queue, :tenant],
        description: "Jobs processed by queue; the busiest tenants by name, the rest as other"
      ),
      counter("relay.request.budget.total",
        event_name: [:relay, :request, :budget],
        tags: [:type, :good],
        description: "API requests by type and whether they stayed within the budget"
      ),
      counter("relay.request.budget_breach.total",
        event_name: [:relay, :request, :budget_breach],
        tags: [:type, :resource],
        description: "API requests over the latency or reduction budget of their type"
      )
    ]
  end

  # T-48
  # T-53 (2)
  @doc "The VM metrics: the periodic sample and the system monitor reports by kind and process label."
  @spec vm_metrics() :: [Telemetry.Metrics.t()]
  def vm_metrics do
    samples =
      for measurement <- @vm_samples do
        last_value("relay.vm.#{measurement}",
          event_name: [:relay, :vm, :sample],
          measurement: measurement,
          description: "VM sample: #{measurement}"
        )
      end

    samples ++
      [
        counter("relay.vm.monitor.total",
          event_name: [:relay, :vm, :monitor],
          tags: [:kind, :process],
          description: "VM system monitor reports"
        )
      ]
  end

  # DS-24
  # T-63
  @doc "The policy lattice's decision counter by decision kind and reason family, both from bounded sets; exported on `/metrics` beside the alarms."
  @spec policy_metrics() :: [Telemetry.Metrics.t()]
  def policy_metrics do
    [
      counter("relay.policy.decision.total",
        event_name: [:relay, :policy, :decision],
        tags: [:decision, :reason],
        description: "Policy lattice decisions recorded on deliveries"
      )
    ]
  end

  # TP-26
  # TP-49
  # TP-50
  # T-63
  @doc "The render counters by channel and result, the render duration by channel and the `template_locale_missing` fallback counter by channel, all tags from bounded sets; exported on `/metrics` beside the alarms."
  @spec render_metrics() :: [Telemetry.Metrics.t()]
  def render_metrics do
    [
      counter("relay.render.total",
        event_name: [:relay, :render, :stop],
        tags: [:channel, :result],
        description: "Renders of pinned template cells on the send path by result"
      ),
      distribution("relay.render.duration",
        event_name: [:relay, :render, :stop],
        measurement: :duration,
        unit: :millisecond,
        tags: [:channel],
        description: "Duration of renders on the send path"
      ),
      counter("relay.template_locale_missing.total",
        event_name: [:relay, :templates, :locale_missing],
        tags: [:channel],
        description: "Deliveries pinned to the tenant's default locale instead of the recipient's"
      )
    ]
  end

  # DS-41
  # DS-48
  # T-63
  @doc "The reconciliation metrics by channel, provider and mode, all from bounded sets: the deliveries asked about and the provider events found, already known and written (`drift`, the events the webhooks missed) per round, the calls that could not be answered, and the lag, the age of the oldest open delivery a status round asked about; exported on `/metrics` beside the alarms."
  @spec reconciliation_metrics() :: [Telemetry.Metrics.t()]
  def reconciliation_metrics do
    tags = [:channel, :provider, :mode]
    event = [:relay, :reconciliation, :round]

    [
      sum("relay.reconciliation.checked.total",
        event_name: event,
        measurement: :checked,
        tags: tags,
        description: "Deliveries or accounts a reconciliation round asked the provider about"
      ),
      sum("relay.reconciliation.found.total",
        event_name: event,
        measurement: :found,
        tags: tags,
        description: "Provider events a reconciliation round found"
      ),
      sum("relay.reconciliation.drift.total",
        event_name: event,
        measurement: :recorded,
        tags: tags,
        description: "Provider events a reconciliation round found that no webhook had brought"
      ),
      sum("relay.reconciliation.unavailable.total",
        event_name: event,
        measurement: :unavailable,
        tags: tags,
        description: "Provider calls of a reconciliation round that could not be answered"
      ),
      last_value("relay.reconciliation.lag.milliseconds",
        event_name: event,
        measurement: :lag_ms,
        tags: tags,
        description: "Age of the oldest open delivery the last status round asked about"
      )
    ]
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
  # PC-50
  # IN-51
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
      last_value("relay.access.subscriber_token_key.activated.timestamp_seconds",
        event_name: [:relay, :access, :subscriber_token_key],
        measurement: :activated_at,
        description: "Activation time of the current subscriber token signing key"
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
      ),
      last_value("relay.access.link.down",
        event_name: [:relay, :access, :link],
        measurement: :down,
        description: "1 while the Access link is not established or its keys are stale"
      ),
      counter("relay.frequency_counter.unavailable.total",
        event_name: [:relay, :frequency_counter, :unavailable],
        description: "Frequency counter reads and writes that Valkey did not answer"
      ),
      counter("relay.push.signing_unavailable.total",
        event_name: [:relay, :push, :signing_unavailable],
        description: "Push provider tokens the key store could not sign"
      )
    ]
  end

  # OP-32
  @doc "Renders the alarm metrics in the Prometheus text exposition format."
  @spec prometheus() :: iolist()
  def prometheus, do: @reporter |> Peep.get_all_metrics() |> Peep.Prometheus.export()

  defp now(_measurements), do: DateTime.to_unix(Relay.Clock.utc_now())
end
