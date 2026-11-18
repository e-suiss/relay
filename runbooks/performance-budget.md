---
id: performance-budget
kind: alert
severity: SEV3
channels: [none]
tenant_scope: all
alerts: [RelayPerformanceBudget]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 120
reversible: true
---

# Performance budget

## Symptom

For 15 minutes, more than 1% of the requests of a request type exceeded their latency or reduction budget (`relay_request_budget_total{type, good}`; the breached resource is in `relay_request_budget_breach_total{type, resource}`). Request types and budgets (accept, inbound, health, link, read, write and the others) come from `priv/observability/budgets.json`.

## Impact

API responses of that type are slower or costlier than designed. No message is lost; producers and console users notice slowness, and an accept slowdown feeds the accept SLO (slo-accept-burn.md). SEV3 on its own; follow the SLO runbook when an SLO alert fires as well.

## Diagnosis

Breach ratio per type and the breached resource:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (type) (rate(relay_request_budget_total{good="false"}[30m])) / sum by (type) (rate(relay_request_budget_total[30m]))' | jq '.data.result'
```

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (type, resource) (rate(relay_request_budget_breach_total[30m]))' | jq '.data.result'
```

`latency` alone means the request waits (database, Valkey, Access, another node); `reductions` means the node does more work per request than budgeted, often after a code change.

The budgets themselves:

```sh
$RELAY_EXEC bin/relay eval 'IO.inspect(Relay.Observability.Budget.table()["types"])'
```

Recent deploys, to line up the start of the breach (default Helm values name the deployment `relay-all`):

```sh
kubectl rollout history deploy/relay-all
```

## Decision tree

```text
type T breaks its budget for more than 1% of requests
├── started with a deploy
│   ├── resource reductions -> code regression: open an issue, consider rollback
│   └── resource latency -> new query or call: compare slow queries before/after
├── no deploy, resource latency
│   └── dependency slow: database, Valkey or Access (their runbooks)
└── no deploy, resource reductions
    └── traffic mix changed (larger batches, bigger payloads): measure, then decide
```

## Mitigation

Measure before optimising. Roll back only when a deploy clearly caused it and the breach also burns an SLO:

```sh state-changing
kubectl rollout undo deploy/relay-all
```

## Fix and escalation

Open an issue with the measurement (type, resource, ratio, start time, deploy). The nightly load run checks the same budgets and opens an issue by itself when a type's p99 is over budget; link the two. Escalate to the engineering owner of the slow path.
