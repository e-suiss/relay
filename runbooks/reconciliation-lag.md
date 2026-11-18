---
id: reconciliation-lag
kind: alert
severity: SEV3
channels: [sms, email, voice, whatsapp]
tenant_scope: some
alerts: [RelayReconciliationLag]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Reconciliation lag

## Symptom

For ten minutes, the oldest open delivery that a reconciliation round asked a provider about is more than 30 minutes past the point it should have been reconciled (`relay_reconciliation_lag_milliseconds{channel, provider, mode}`). Rounds are queued every five minutes by `Relay.Channels.Live.ReconcileSweep` and run as `Relay.Channels.Live.ReconcileWorker` jobs on the `maintenance` queue; what is reconciled and how often comes from the active `reconciliation` data set.

## Impact

Deliveries whose provider receipt was lost stay `unknown_pending` longer before their final state is known. Nothing is resent and nothing is lost; tenants see stale states and reports are late. SEV3.

## Diagnosis

Lag and unavailable provider answers per channel and provider:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (channel, provider, mode) (relay_reconciliation_lag_milliseconds)' | jq '.data.result'
```

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (channel, provider) (increase(relay_reconciliation_unavailable_total[1h]))' | jq '.data.result'
```

Many `unavailable` answers mean the provider's status API fails or limits Relay.

Reconciliation jobs that wait, retry or failed (admin connection for the queue schema):

```sh
psql "$PG_ADMIN_URL" -c "SELECT worker, state, count(*), min(scheduled_at), max(attempted_at) FROM relay_queue.oban_jobs WHERE worker IN ('Relay.Channels.Live.ReconcileSweep', 'Relay.Channels.Live.ReconcileWorker') AND inserted_at > now() - interval '6 hours' GROUP BY 1, 2 ORDER BY 1, 2"
```

The latest errors of failed rounds:

```sh
psql "$PG_ADMIN_URL" -c "SELECT id, args->>'provider' AS provider, attempt, errors[array_length(errors, 1)]->>'error' AS last_error FROM relay_queue.oban_jobs WHERE worker = 'Relay.Channels.Live.ReconcileWorker' AND state IN ('retryable', 'discarded') ORDER BY id DESC LIMIT 10"
```

## Decision tree

```text
reconciliation lag above 30 minutes for provider P
├── no ReconcileSweep job completed recently
│   └── maintenance queue not draining: queue-oldest-job.md
├── ReconcileWorker jobs retry/discard
│   ├── errors are auth/credential -> tenant's provider credentials: tell the tenant
│   └── errors are timeouts/5xx/429 -> P's status API degraded: provider case, wait
└── jobs complete but lag stays
    └── more open deliveries than a round covers: raise per_round in a new data set version
```

## Mitigation

Nothing to stop. Restore the cause: the maintenance queue, the provider's status API or the tenant's credentials. When the backlog is only volume, publish a new version of the `reconciliation` data set with a larger `per_round` through the normal data set change; the change is reviewed and versioned.

## Fix and escalation

Escalate provider status API problems to the provider. Unknown deliveries stay unknown until reconciled; delivery windows still apply. When the lag persists for a day, escalate to engineering.
