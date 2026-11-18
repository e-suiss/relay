---
id: slo-accept-burn
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelaySloAcceptFastBurn, RelaySloAcceptSlowBurn, RelaySloAcceptBudgetBurn]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Accept latency SLO burn

## Symptom

The accept latency SLI of a message class (`relay_slo_accept_total{class, good}`) has too many requests over the class threshold. `RelaySloAcceptFastBurn` (1 h and 5 min windows, 14.4x) and `RelaySloAcceptSlowBurn` (6 h and 30 min, 6x) page; `RelaySloAcceptBudgetBurn` (3 days and 6 h, 1x) opens a ticket. The alert's `class` label names the class.

## Impact

Producers wait longer for `202` on `POST /v1/events` and batches of that class. Nothing is lost while requests still succeed, but slow accepts make producers time out and retry, and timeouts on `security` (one-time codes) are visible to end users at once. A fast burn on `security`, `transactional` or `action_required` that turns into failed accepts is SEV1; a ticket-only burn is SEV3.

## Diagnosis

Error ratio per class over the alert windows:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay:slo_accept_errors:ratio_rate5m' | jq '.data.result[] | {class: .metric.class, ratio: .value[1]}'
```

The class thresholds the SLI uses (accept_ms per class):

```sh
$RELAY_EXEC bin/relay eval 'IO.inspect(Relay.Observability.Slo.table()["classes"])'
```

Whether the accept request type also breaks its performance budget, and on which resource (latency or reductions):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (resource) (rate(relay_request_budget_breach_total{type="accept"}[15m]))' | jq '.data.result'
```

`resource="latency"` alone points at waiting (database, Valkey, Access); `reductions` points at CPU work inside the node.

Database health from the node's point of view and the readiness of the nodes:

```sh
curl -fsS "$RELAY_URL/readyz"
```

Load shedding state per lane on the node you exec into:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(for lane <- Relay.Platform.Lane.all(), do: {lane, Relay.Platform.load_shed_engaged?(lane)})'
```

Long queries and lock waits on the database:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT wait_event_type, wait_event, count(*) FROM pg_stat_activity WHERE state <> 'idle' GROUP BY 1, 2 ORDER BY 3 DESC"
```

Many sessions waiting on `Lock` or `LWLock` means the database is the bottleneck, not the API nodes.

## Decision tree

```text
accept SLI burning for class C
├── /readyz not ok on some nodes
│   └── fix that dependency first (postgres-failover.md, valkey-loss.md)
├── budget breaches are "reductions"
│   └── CPU bound on API nodes: add API nodes (capacity-incident.md, step "node count")
├── budget breaches are "latency"
│   ├── database sessions waiting on locks or I/O
│   │   └── database bottleneck: do NOT add nodes; follow capacity-incident.md, step "database"
│   └── database calm
│       └── look at Access link and Valkey latency; see access-link-down.md, valkey-loss.md
└── only RelaySloAcceptBudgetBurn (ticket)
    └── no action tonight; plan the fix within the 28-day window
```

## Mitigation

Shedding of bulk lanes is automatic; protect the urgent classes by stopping the bulk producer that drives the load. A campaign or workflow can be stopped with a scoped kill switch (the tenant and identifiers come from the console):

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"accept latency burn\", ttl: \"2h\", scope: :campaign, scope_ref: \"cmp_REPLACE\", tenant: \"ten_REPLACE\", environment: :live))"
```

If the API nodes are CPU bound and the database is calm, add API nodes (Kubernetes example; the Helm chart names a deployment `<release>-<node>`, `relay-all` with the default values):

```sh state-changing
kubectl scale deploy/relay-all --replicas=6
```

## Fix and escalation

Find the slow step before scaling further: compare the latency with the last deploy and with the database's slow queries. A slow burn that keeps coming back is a capacity plan item (capacity-incident.md). Escalate to the database owner when the database is the bottleneck and to the Access on-call when the Access link is slow.
