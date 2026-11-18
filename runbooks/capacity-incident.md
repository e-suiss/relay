---
id: capacity-incident
kind: procedure
severity: SEV2
channels: [all]
tenant_scope: some
alerts: []
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Capacity incident

## Symptom

Queues grow and messages leave late: `RelayQueueOldestJob`, the handoff SLO burn alerts or `RelayNoisyNeighbour` fire, load shedding engages lanes, or a known peak (a campaign day, a holiday, the end of the month) is about to start.

## Impact

Late messages first, then lost value: a one-time code that arrives after it expires, a reminder after the event. Load shedding holds `marketing` before `transactional` and never `security`; if the `l0` lane sheds, security messages are late and it is SEV1.

## Diagnosis

Work in this order and stop at the first layer that is the bottleneck: provider capacity, then queue limits, then node count, then the database. Adding nodes does not help when the database is the bottleneck, and it makes a retry storm worse.

Which lanes are late and by how much:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (lane) (relay_queue_oldest_job_age_seconds)'
```

Which lanes load shedding has engaged, and since when:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT * FROM relay_ops.load_shed_state()"
```

1. Provider capacity: an open breaker or rate limiting at the provider means the provider is the limit:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (provider) (relay_breaker_open) == 1'
```

2. What kind of load: one tenant or API client dominating (abuse), a spread of tenants (real demand), or normal acceptance with many retries (retry storm):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (signal, queue) (relay_noisy_neighbour_share)'
```

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=topk(5, sum by (tenant, queue) (rate(relay_jobs_processed_total[5m])))'
```

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT provider, count(*) AS attempts, count(DISTINCT delivery_id) AS deliveries, round(count(*)::numeric / greatest(count(DISTINCT delivery_id), 1), 2) AS attempts_per_delivery FROM relay.delivery_attempts WHERE created_at > now() - interval '15 minutes' GROUP BY 1 ORDER BY 2 DESC"
```

More than about 1.5 attempts per delivery while acceptance is normal means a retry storm.

3. Queue limits: jobs waiting per queue:

```sh
psql "$PG_ADMIN_URL" -c "SELECT queue, state, count(*) FROM relay_queue.oban_jobs WHERE state IN ('available', 'scheduled', 'retryable', 'executing') GROUP BY 1, 2 ORDER BY 3 DESC"
```

4. Nodes and the database: CPU-bound nodes with an idle database call for nodes; a busy database (waiting connections, slow queries) does not:

```sh
psql "$PG_ADMIN_URL" -c "SELECT state, wait_event_type, count(*) FROM pg_stat_activity WHERE datname = current_database() GROUP BY 1, 2 ORDER BY 3 DESC"
```

## Decision tree

```text
messages leave late
├── l0 lane shedding or security late -> SEV1, declare now
├── provider breaker open or provider rate limiting
│   └── provider is the limit: fail over if a fallback provider exists,
│       ask the provider for quota; do not add nodes
├── one tenant or API client > 50% of the load (abuse)
│   └── tenant limit, canary or kill switch on that tenant/campaign
├── attempts per delivery high, acceptance normal (retry storm)
│   └── slow down: kill switch canary on the affected provider account;
│       do not scale
├── jobs pile up in one queue while nodes are idle
│   └── queue limit: raise that queue's concurrency in the deploy config
├── nodes CPU-bound, database calm (real demand, spread)
│   └── add nodes
└── database busy (waits, slow queries, pool exhausted)
    └── do not add nodes: shed marketing, find the query, escalate to DB owner
```

## Mitigation

Abuse by one tenant: hold it with a tenant kill switch in canary (here 10 % of its traffic passes) while the account team talks to the tenant:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"capacity: tenant flood\", ttl: \"1h\", scope: :tenant, tenant: \"ten_REPLACE\", environment: :live, state: {:canary, 10}))"
```

Real demand on calm database: add nodes (Kubernetes example):

```sh state-changing
kubectl scale deploy/relay-all --replicas=6
```

Database bottleneck: hold `marketing` everywhere until the database recovers:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"capacity: database\", ttl: \"1h\", scope: :platform, message_class: :marketing))"
```

## Fix and escalation

A known peak is a project, planned weeks before: provider quota increases, template approvals, a load test (`load/run.sh`), a kill switch drill and a change freeze. Escalate a database bottleneck to the database owner on call; escalate provider limits to the provider's account manager. Record the measured throughput in the postmortem so the capacity assumptions get real numbers.
