---
id: funnel-data-loss
kind: alert
severity: SEV1
channels: [all]
tenant_scope: some
alerts: [RelayFunnelDataLoss]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Funnel data loss

## Symptom

`relay_funnel_gap{gap="accepted_enqueued"} > 0`: deliveries recorded as queued between 5 and 65 minutes ago have `decision = 'send'`, no attempt, no failure, no deferral, no pause, and no job in the queue or in the tenant wait table. The `observability_rollup` task computes it every minute from the ledger.

## Impact

Accepted messages that will never be sent unless someone acts: this breaks the core promise that an accepted request is durably queued. SEV1, whatever the class.

## Diagnosis

Gap per channel and provider:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (channel, provider) (relay_funnel_gap{gap="accepted_enqueued"})' | jq '.data.result'
```

The deliveries themselves (the admin connection is needed to look into the queue schema):

```sh
psql "$PG_ADMIN_URL" -c "SELECT d.tenant_id, d.environment, d.id, d.channel, d.provider, d.created_at FROM relay.deliveries d WHERE d.created_at > now() - interval '70 minutes' AND d.decision = 'send' AND d.attempt_count = 0 AND d.failure_kind IS NULL AND d.deferred_until IS NULL AND d.paused_at IS NULL AND NOT EXISTS (SELECT 1 FROM relay_queue.oban_jobs j WHERE j.args->>'delivery_id' = d.id::text) AND NOT EXISTS (SELECT 1 FROM relay_queue.drr_waits w WHERE w.args->>'delivery_id' = d.id::text) ORDER BY d.created_at LIMIT 50"
```

Save this output in the incident record before anything changes: it is the evidence.

When the gap started compared with the last deploy:

```sh
kubectl rollout history deploy/relay-all
```

Whether the rollup itself runs (a stale value would not move):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT name, leader_node, lease_until, updated_at FROM relay.singleton_tasks WHERE name = 'observability_rollup'"
```

## Decision tree

```text
accepted deliveries without a job
├── started right after a deploy
│   └── roll back the deploy (Mitigation), keep the list of deliveries
├── only l2/l3 channels (DRR wait table)
│   └── dispatcher not moving waits: check the `drr_dispatcher` row in relay.singleton_tasks (singleton-leaderless.md)
└── no deploy, all lanes
    └── accepting transaction broken by a database change: escalate at once
```

## Mitigation

Stop the change that broke the accepting transaction. On Kubernetes, roll back the Relay deployment to the previous revision (`<release>-<node>`; `relay-all` with the default values):

```sh state-changing
kubectl rollout undo deploy/relay-all
```

Do not re-insert jobs by hand: a send job inserted outside the lane's dispatcher bypasses fairness and lane budgets. There is no operator command to requeue such deliveries; engineering requeues them from the saved list once the cause is fixed.

## Fix and escalation

Escalate to the Relay engineering owner immediately with the saved list and the deploy revision. Write the postmortem (mandatory: messages were accepted and not sent). Tell the affected tenants through the status page, not through Relay.
