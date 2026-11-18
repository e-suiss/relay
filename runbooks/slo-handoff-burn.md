---
id: slo-handoff-burn
kind: alert
severity: SEV2
channels: [all]
tenant_scope: some
alerts: [RelaySloHandoffFastBurn, RelaySloHandoffSlowBurn, RelaySloHandoffBudgetBurn]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Provider handoff latency SLO burn

## Symptom

Too many deliveries of a message class reach the provider later than the class's handoff threshold, counted from the ledger (`relay_slo_handoff_total{class, channel, provider, good}`). Deferrals for quiet hours, frequency caps, `send_at` and provider limits are not counted, so the delay is Relay's or the provider's. The fast (14.4x) and slow (6x) burns page, the 3-day budget burn opens a ticket. Labels name the class, channel and provider.

## Impact

Messages of that class on that channel and provider arrive late. One-time codes and alerts that arrive late are as bad as lost: a `security` or `transactional` handoff burn is SEV1 when codes expire before they arrive; otherwise SEV2, and SEV3 for the ticket.

## Diagnosis

Which class, channel and provider burn now:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay:slo_handoff_errors:ratio_rate5m > 0' | jq '.data.result[] | {class: .metric.class, channel: .metric.channel, provider: .metric.provider, ratio: .value[1]}'
```

The oldest waiting job per lane (the lane of the class: `security` l0, `transactional`/`action_required` l1, `operational`/`system`/`social` l2, `marketing` l3):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (lane) (relay_queue_oldest_job_age_seconds)' | jq '.data.result'
```

An old job in the lane means the delay is in Relay's queue; a fresh queue with a burning SLI means the provider call itself is slow or limited.

Provider breaker state (1 = open):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (provider) (relay_breaker_open)' | jq '.data.result'
```

Attempt durations at the provider over the last 15 minutes:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT provider, count(*), percentile_cont(0.95) WITHIN GROUP (ORDER BY finished_at - started_at) AS p95 FROM relay.delivery_attempts WHERE started_at > now() - interval '15 minutes' AND finished_at IS NOT NULL GROUP BY provider ORDER BY p95 DESC"
```

## Decision tree

```text
handoff SLI burning for class C on channel/provider P
├── breaker of P open
│   └── provider-breaker-open.md
├── oldest job of the lane above its threshold
│   └── queue-oldest-job.md (capacity order: provider, queue limit, nodes, database)
├── queue fresh, p95 attempt duration of P high
│   └── provider slow: check P's status page; fail over if a fallback route exists
└── only RelaySloHandoffBudgetBurn (ticket)
    └── open a ticket with the provider or the capacity plan
```

## Mitigation

Do not add worker nodes before the provider has capacity: more workers against a limited provider only add retries. When a fallback provider is configured for the route, move traffic in the console route editor (route changes are audited and versioned). When marketing load slows the urgent lanes on the same provider account, pause the marketing campaign with a scoped kill switch:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"handoff burn: free provider capacity\", ttl: \"2h\", scope: :campaign, scope_ref: \"cmp_REPLACE\", tenant: \"ten_REPLACE\", environment: :live))"
```

## Fix and escalation

Ask the provider for more throughput or a higher quota when the provider limits; raise the lane budget or add nodes only when the queue is the bottleneck and the provider has room (capacity-incident.md). Escalate to the provider's support with the attempt timings above. A recurring budget burn is a capacity plan item.
