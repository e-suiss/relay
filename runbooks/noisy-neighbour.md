---
id: noisy-neighbour
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelayNoisyNeighbour]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Noisy neighbour

## Symptom

For ten minutes one tenant or API client makes up more than half of a signal (`relay_noisy_neighbour_share{signal, queue} > 0.5`). The signals are `queue_tenant` (processed jobs of a queue, per tenant), `queue_queued` (waiting jobs of a queue, per tenant) and `api_client` (accepted API requests, per client). Shares are only reported when the window saw at least 100 items, so quiet installations stay silent.

## Impact

Fairness should keep other tenants served: the bulk lanes run a weighted round robin over tenants and the API limits each tenant. A dominant tenant still shows up as longer waits for the others when the lane is near capacity. SEV3; SEV2 when other tenants' handoff SLOs burn at the same time; it can also be abuse (a leaked credential, a loop in the tenant's code).

## Diagnosis

Which signal and queue:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_noisy_neighbour_share > 0.5' | jq '.data.result[] | {signal: .metric.signal, queue: .metric.queue, share: .value[1]}'
```

The busiest tenants by processed jobs (the tenant label is kept for the top tenants, the rest is `other`):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=topk(5, sum by (tenant, queue) (rate(relay_jobs_processed_total[10m])))' | jq '.data.result'
```

Waiting work per tenant in the bulk lanes, with the weight the dispatcher uses (admin connection for the queue schema):

```sh
psql "$PG_ADMIN_URL" -c "SELECT tenant_id, environment, lane, weight, pending_count, pending_cost FROM relay_queue.drr_tenants WHERE active ORDER BY pending_count DESC LIMIT 10"
```

Whether the others suffer (handoff SLO burning or lanes over threshold):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=ALERTS{alertstate="firing",alertname=~"RelaySloHandoff.*|RelayQueueOldestJob"}' | jq '.data.result[] | .metric'
```

## Decision tree

```text
one tenant or client above 50% of signal S
├── others unaffected (no SLO or lane alerts)
│   └── legitimate peak: nothing to do; note it for the account team
├── others' handoff burns or lanes over threshold
│   ├── tenant's traffic expected (campaign day) -> lower its bulk weight or pause its campaign
│   └── traffic unexpected (loop, leaked credential) -> abuse: scoped kill switch, contact the tenant
└── signal api_client
    └── one client floods the API: the tenant's rate tiers apply; contact the tenant
```

## Mitigation

For a legitimate but heavy tenant, a tenant administrator or operator lowers the tenant's bulk lane weight (`fairness.weight.l2` or `fairness.weight.l3`, 1 to 100) or its API rate tiers (`api.rate.burst`, `api.rate.sustained`) in the console tenant settings (`PUT /v1/operator/settings`, audited). For abuse, stop the tenant's traffic on the affected channel while you reach the tenant:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"noisy neighbour: suspected abuse\", ttl: \"1h\", scope: :tenant, tenant: \"ten_REPLACE\", environment: :live, channel: \"sms\"))"
```

Do not add nodes to absorb abuse.

## Fix and escalation

Contact the tenant through the account team with the volumes. A tenant that regularly dominates a lane needs an agreed quota or its own installation. Suspected credential leaks go to the security on-call.
