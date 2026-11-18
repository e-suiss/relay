---
id: queue-oldest-job
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelayQueueOldestJob]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Oldest job of a lane

## Symptom

For five minutes, the oldest job waiting in a lane is older than the lane's threshold (`relay_queue_oldest_job_age_seconds{lane}` above `relay:queue_age_threshold_seconds`: l0 5 s, l1 30 s, l2 30 s, l3 30 minutes). The load shedding controller samples the age on the database clock.

## Impact

Every message of the lane's classes waits: l0 is `security`, l1 `transactional` and `action_required`, l2 `operational`, `system` and `social`, l3 `marketing`. l0 or l1 waiting is SEV1 when codes and alerts arrive too late to be useful; l2 SEV2; l3 SEV3 (marketing does not page at night).

## Diagnosis

Age per lane and shedding state:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (lane) (relay_queue_oldest_job_age_seconds)' | jq '.data.result'
```

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(for lane <- Relay.Platform.Lane.all(), do: {lane, Relay.Platform.load_shed_engaged?(lane)})'
```

Recent shedding transitions:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT created_at, lane, phase, rule_id, sample_ms, target_ms FROM relay.load_shed_events ORDER BY created_at DESC LIMIT 20"
```

Backlog per queue and state (admin connection for the queue schema):

```sh
psql "$PG_ADMIN_URL" -c "SELECT queue, state, count(*), min(scheduled_at) FROM relay_queue.oban_jobs WHERE state IN ('available', 'scheduled', 'retryable', 'executing') GROUP BY 1, 2 ORDER BY 1, 2"
```

Many `retryable` jobs with a normal `available` count is a retry storm, not demand.

Tenant wait table of the bulk lanes (l2, l3) and the dispatcher's leadership:

```sh
psql "$PG_ADMIN_URL" -c "SELECT lane, count(*), min(created_at) FROM relay_queue.drr_waits WHERE state = 'waiting' GROUP BY lane"
```

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT name, leader_node, lease_until, updated_at FROM relay.singleton_tasks WHERE name IN ('drr_dispatcher', 'load_shed_controller')"
```

Provider breakers (1 = open) and noisy tenants:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (provider) (relay_breaker_open) or max by (signal, queue) (relay_noisy_neighbour_share)' | jq '.data.result'
```

## Decision tree

```text
oldest job of lane L above threshold
├── jobs are retryable, provider breaker open or provider limiting
│   └── retry storm: do NOT scale; provider-breaker-open.md, capacity-incident.md
├── one tenant over half of the queue (noisy neighbour share > 0.5)
│   └── noisy-neighbour.md
├── l2/l3 waits growing, drr_dispatcher lease expired
│   └── singleton-leaderless.md
├── available jobs growing, workers busy, provider has room, database calm
│   └── real demand: add worker nodes (Mitigation)
└── database sessions waiting on locks or I/O
    └── database bottleneck: do NOT add nodes; capacity-incident.md, step "database"
```

## Mitigation

Follow the capacity order: provider capacity first, then the queue limit, then node count, then the database. Only when the provider has room and the database is calm, add worker nodes (Kubernetes example; the Helm chart names a deployment `<release>-<node>`, `relay-all` with the default values):

```sh state-changing
kubectl scale deploy/relay-all --replicas=6
```

When a marketing campaign starves the bulk lanes, pause it with a scoped kill switch:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"lane backlog\", ttl: \"2h\", scope: :campaign, scope_ref: \"cmp_REPLACE\", tenant: \"ten_REPLACE\", environment: :live))"
```

## Fix and escalation

A lane that keeps reaching its threshold is a capacity plan item: provider quota, lane budgets, node count. Escalate to engineering when the dispatcher or the controller does not move with a leader present.
