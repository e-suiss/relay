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
      webhook_metrics() ++
      iys_metrics() ++
      agent_metrics() ++
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

  # WH-10
  # WH-21
  # WH-28
  # WH-30
  # WH-39
  # WH-56
  # T-63
  @doc "The webhook delivery metrics, all from bounded sets: attempts and their duration by result, trigger and whether it was a message's first attempt; object store batch writes with their events, bytes and duration by result; what the sweep rescued, queued again, ended and handed back to a batch write; the age of the oldest waiting message; what the daily maintenance retired, destroyed and erased; and the operations e-mails by kind and result."
  @spec webhook_metrics() :: [Telemetry.Metrics.t()]
  def webhook_metrics do
    attempt = [:relay, :webhooks, :attempt]
    batch = [:relay, :webhooks, :batch]
    sweep = [:relay, :webhooks, :sweep]
    maintenance = [:relay, :webhooks, :maintenance]

    [
      sum("relay.webhooks.attempt.total",
        event_name: attempt,
        measurement: :count,
        tags: [:result, :trigger, :first],
        description: "Webhook delivery attempts by result, trigger and first attempt"
      ),
      distribution("relay.webhooks.attempt.duration",
        event_name: attempt,
        measurement: :duration_ms,
        unit: :millisecond,
        tags: [:result],
        description: "Duration of webhook delivery attempts"
      ),
      sum("relay.webhooks.batch.total",
        event_name: batch,
        measurement: :count,
        tags: [:result],
        description: "Object store batch writes by result"
      ),
      sum("relay.webhooks.batch.events.total",
        event_name: batch,
        measurement: :events,
        tags: [:result],
        description: "Events settled by object store batch writes"
      ),
      sum("relay.webhooks.batch.bytes.total",
        event_name: batch,
        measurement: :bytes,
        tags: [:result],
        description: "Bytes of the objects object store batch writes sent"
      ),
      distribution("relay.webhooks.batch.duration",
        event_name: batch,
        measurement: :duration_ms,
        unit: :millisecond,
        tags: [:result],
        description: "Duration of object store batch writes"
      ),
      sum("relay.webhooks.sweep.rescued.total",
        event_name: sweep,
        measurement: :rescued,
        description: "Webhook messages picked up after their attempt's lock ran out"
      ),
      sum("relay.webhooks.sweep.requeued.total",
        event_name: sweep,
        measurement: :requeued,
        description: "Webhook messages long due without a job and queued again"
      ),
      sum("relay.webhooks.sweep.expired.total",
        event_name: sweep,
        measurement: :expired,
        description: "Webhook messages held past their delivery time"
      ),
      sum("relay.webhooks.sweep.window_exceeded.total",
        event_name: sweep,
        measurement: :window_exceeded,
        description: "Webhook messages that waited behind an open breaker past their window"
      ),
      sum("relay.webhooks.sweep.batches.total",
        event_name: sweep,
        measurement: :batches,
        description: "Object store batches whose write the sweep queued again"
      ),
      last_value("relay.webhooks.backlog.age.milliseconds",
        event_name: [:relay, :webhooks, :backlog],
        measurement: :age_ms,
        description: "Age of the oldest webhook message waiting for an attempt in a swept scope"
      ),
      sum("relay.webhooks.maintenance.keys_retired.total",
        event_name: maintenance,
        measurement: :keys_retired,
        description: "Webhook signing keys retired after their rotation overlap"
      ),
      sum("relay.webhooks.maintenance.keys_destroyed.total",
        event_name: maintenance,
        measurement: :keys_destroyed,
        description: "Retired webhook signing keys destroyed in the key store"
      ),
      sum("relay.webhooks.maintenance.responses.total",
        event_name: maintenance,
        measurement: :responses,
        description: "Stored webhook answers erased at the end of their retention"
      ),
      sum("relay.webhooks.maintenance.payloads.total",
        event_name: maintenance,
        measurement: :payloads,
        description: "Stored webhook event payloads erased at the end of their retention"
      ),
      sum("relay.webhooks.operations_email.total",
        event_name: [:relay, :webhooks, :operations_email],
        measurement: :count,
        tags: [:kind, :result],
        description: "Webhook operations e-mails by kind and result"
      ),
      sum("relay.webhooks.completion.total",
        event_name: [:relay, :webhooks, :completion],
        measurement: :count,
        tags: [:result],
        description: "Processed job completion notifications by result"
      )
    ]
  end

  # T-6
  # T-68 (3)
  # TN-62
  # OP-88
  # OP-30
  @doc "The operations metrics: oldest job age and depth per lane, the connection pooling rule, database pool load shedding, provider breaker state, noisy neighbour shares, jobs per tenant (busiest tenants only) and the request budget counters."
  @spec operations_metrics() :: [Telemetry.Metrics.t()]
  def operations_metrics do
    [
      last_value("relay.queue.oldest_job_age.seconds",
        event_name: [:relay, :load_shed, :delay],
        measurement: fn %{ms: ms} -> ms / 1000 end,
        tags: [:lane],
        description: "Age of the oldest job waiting in each lane"
      ),
      last_value("relay.queue.depth",
        event_name: [:relay, :queue, :depth],
        measurement: :count,
        tags: [:lane],
        description: "Available jobs waiting in each lane, capped at 100000"
      ),
      last_value("relay.postgres.pool_rule.exceeded",
        event_name: [:relay, :postgres, :pool_rule],
        measurement: :exceeded,
        description:
          "1 when the nodes' connection demand exceeds half of max_connections without a pooler"
      ),
      last_value("relay.postgres.pool_rule.demand",
        event_name: [:relay, :postgres, :pool_rule],
        measurement: :demand,
        description: "Connection demand of the installation: nodes times pool times two"
      ),
      counter("relay.postgres.pool_shed.total",
        event_name: [:relay, :postgres, :pool_shed],
        description: "API requests answered 503 because no database connection was free in time"
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
      sum("relay.audit.stream.records.total",
        event_name: [:relay, :audit, :stream],
        measurement: :count,
        tags: [:target, :result],
        description: "Audit records streamed to a target, by result"
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
  @doc "The policy lattice's decision counter by decision kind and reason family and its counter of deliveries sent with an inferred time zone by the zone's source (WF-46), all from bounded sets; exported on `/metrics` beside the alarms."
  @spec policy_metrics() :: [Telemetry.Metrics.t()]
  def policy_metrics do
    [
      counter("relay.policy.decision.total",
        event_name: [:relay, :policy, :decision],
        tags: [:decision, :reason],
        description: "Policy lattice decisions recorded on deliveries"
      ),
      counter("relay.policy.fallback_zone.total",
        event_name: [:relay, :policy, :fallback_zone],
        tags: [:source],
        description: "Deliveries sent with an inferred time zone, by the zone's source"
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
  # E-104
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
      last_value("relay.access.pairing.unpaired_access_environments",
        event_name: [:relay, :access, :pairing],
        measurement: :unpaired_access_environments,
        description: "Access environments of Access tenants unpaired after three runs in a row"
      ),
      counter("relay.frequency_counter.unavailable.total",
        event_name: [:relay, :frequency_counter, :unavailable],
        description: "Frequency counter reads and writes that Valkey did not answer"
      ),
      counter("relay.push.signing_unavailable.total",
        event_name: [:relay, :push, :signing_unavailable],
        description: "Push provider tokens the key store could not sign"
      ),
      counter("relay.keys.custody_unavailable.total",
        event_name: [:relay, :keys, :custody_unavailable],
        description: "Reads refused because a tenant's own key was unavailable"
      ),
      counter("relay.access.event_unresolved.total",
        event_name: [:relay, :access, :event, :unresolved],
        tags: [:kind],
        description: "Access account events Relay could not map to a pairwise sub"
      )
    ]
  end

  # PC-32
  # PC-33
  # PC-62
  # OP-42
  @doc "The İYS read path metrics: the brands whose local copy of İYS is past the warning and the stop age, the brands at the warning and at the limit of the direct access threshold and the drift the reconciliations found, all measured across tenants by the synchronisation sweep; the pulls by result, the rejections that came from İYS by what became of them, and the marketing deliveries the lattice evaluated against a copy past the warning age."
  @spec iys_metrics() :: [Telemetry.Metrics.t()]
  def iys_metrics do
    overview = [:relay, :iys, :sync, :overview]

    [
      last_value("relay.iys.copy.warning_brands",
        event_name: overview,
        measurement: :stale_warning,
        description: "İYS brands whose local copy is past the warning age"
      ),
      last_value("relay.iys.copy.stopped_brands",
        event_name: overview,
        measurement: :stale_stopped,
        description: "İYS brands whose local copy is past the stop age; their marketing is held"
      ),
      last_value("relay.iys.direct_access.warning_brands",
        event_name: overview,
        measurement: :address_warning,
        description: "Integrator brands past the warning share of the direct access threshold"
      ),
      last_value("relay.iys.direct_access.reached_brands",
        event_name: overview,
        measurement: :address_reached,
        description: "Integrator brands at or over the direct access threshold"
      ),
      last_value("relay.iys.reconciliation.drift",
        event_name: overview,
        measurement: :drift,
        description: "Movements the last İYS reconciliations found missing from the local copy"
      ),
      counter("relay.iys.pull.total",
        event_name: [:relay, :iys, :sync, :pull],
        tags: [:result],
        description: "İYS pulls of a brand's consent movements, by result"
      ),
      counter("relay.iys.rejection.total",
        event_name: [:relay, :iys, :sync, :rejection],
        tags: [:result],
        description: "Rejections that came from İYS, by whether a recipient had the address"
      ),
      counter("relay.policy.iys_copy_stale.total",
        event_name: [:relay, :policy, :iys_copy_stale],
        description: "Marketing deliveries evaluated against an İYS copy past the warning age"
      )
    ]
  end

  # AG-48
  # AG-50
  # AG-54
  # AG-71
  @doc "The agent metrics: the agent notifications held at an agent ceiling by reason (`exceeded` or `counter_unreadable`) and those no agent could be named for; and the agent operations gauges the missed-timer sweep measures across tenants: silent and stalled waitpoints, the responses of the last hour and their median response time, the response rate and opened volume of the last day beside those of the seven days before, the share of waitpoints resolved through an escalation, the responses of the last seven days by evidence level, and the held notifications and open ceiling events."
  @spec agent_metrics() :: [Telemetry.Metrics.t()]
  def agent_metrics do
    overview = [:relay, :agents, :operations, :overview]

    gauges = [
      {"relay.agents.waitpoints.silent", :silent_waitpoints,
       "Open or stalled waitpoints whose state has not changed for the silence period"},
      {"relay.agents.waitpoints.stalled", :stalled_waitpoints, "Stalled waitpoints"},
      {"relay.agents.responses.hour", :responses_hour, "Waitpoint responses of the last hour"},
      {"relay.agents.response.median.milliseconds", :median_response_ms,
       "Median time from opening to response of the responses of the last hour"},
      {"relay.agents.waitpoints.opened.day", :opened_day,
       "Question and review waitpoints opened in the last day"},
      {"relay.agents.waitpoints.opened.daily_average", :opened_daily_average,
       "Daily average of the waitpoints opened in the seven days before the last day"},
      {"relay.agents.response.rate.percent", :response_rate_day,
       "Responses per opened waitpoint of the last day, in percent"},
      {"relay.agents.response.rate.previous.percent", :response_rate_week,
       "Responses per opened waitpoint of the seven days before the last day, in percent"},
      {"relay.agents.escalation.share.percent", :escalation_share,
       "Share of the waitpoints resolved in seven days by a responder an escalation added"},
      {"relay.agents.ceiling.held", :held_notifications,
       "Agent notifications held at an agent ceiling for the owner's decision"},
      {"relay.agents.ceiling.open_events", :open_ceiling_events,
       "Agent ceiling events the owner has not decided"}
    ]

    overview_gauges =
      for {name, measurement, description} <- gauges do
        last_value(name, event_name: overview, measurement: measurement, description: description)
      end

    overview_gauges ++
      [
        last_value("relay.agents.responses.evidence",
          event_name: [:relay, :agents, :operations, :evidence],
          measurement: :count,
          tags: [:level],
          description: "Waitpoint responses of the last seven days by evidence level"
        ),
        counter("relay.agents.ceiling.held.total",
          event_name: [:relay, :agents, :ceiling, :held],
          tags: [:reason],
          description: "Agent notifications held at an agent ceiling, by reason"
        ),
        counter("relay.agents.ceiling.unattributed.total",
          event_name: [:relay, :agents, :ceiling, :unattributed],
          description: "Agent notifications that named no agent and were kept from sending"
        )
      ]
  end

  # OP-32
  @doc "Renders the alarm metrics in the Prometheus text exposition format."
  @spec prometheus() :: iolist()
  def prometheus, do: @reporter |> Peep.get_all_metrics() |> Peep.Prometheus.export()

  defp now(_measurements), do: DateTime.to_unix(Relay.Clock.utc_now())
end
