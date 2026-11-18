---
id: reconciliation-drift
kind: alert
severity: SEV3
channels: [sms, email, voice, whatsapp]
tenant_scope: some
alerts: [RelayReconciliationDrift]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Reconciliation drift

## Symptom

A reconciliation round found provider events that the webhooks never brought (`relay_reconciliation_drift_total{channel, provider, mode}` increased in the last hour). The node logs `reconciliation found provider events the webhooks missed` with the channel, provider, mode and count. The events are recorded through the same durable receipts as a webhook, with `actor = provider_api`.

## Impact

The ledger is now right, but the projection was wrong until the round ran, and the webhook path is losing events. Tenants may have seen wrong states, and suppressions after bounces were applied late. SEV3; SEV2 when drift is large and steady on a provider (the webhook path is effectively down: see esp-events.md for e-mail).

## Diagnosis

Drift and checked counts per provider over the last day:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (channel, provider, mode) (increase(relay_reconciliation_drift_total[1d]))' | jq '.data.result'
```

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (channel, provider, mode) (increase(relay_reconciliation_checked_total[1d]))' | jq '.data.result'
```

A drift close to the checked count means the webhooks bring almost nothing.

Ledger entries written by reconciliation in the last day, by provider and event:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT provider, event_type, count(*) FROM relay.delivery_events WHERE actor = 'provider_api' AND received_at > now() - interval '1 day' GROUP BY 1, 2 ORDER BY 3 DESC"
```

Webhook receipts per provider for the same period, to compare:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT provider, state, count(*) FROM relay.webhook_receipts WHERE received_at > now() - interval '1 day' GROUP BY 1, 2 ORDER BY 1, 2"
```

## Decision tree

```text
reconciliation recorded events the webhooks missed for P
├── webhook receipts for P near zero
│   └── webhook path down: check P's subscription and signing secret (esp-events.md for e-mail)
├── receipts present, some rejected
│   └── signature failures: provider rotated its secret; update the provider account's secret
└── receipts present and accepted, small steady drift
    └── P drops some callbacks: record it, raise with P
```

## Mitigation

Nothing to stop: the ledger keeps the reconciled evidence and the projection follows it. Restore the webhook path when it is down (provider console subscription, the provider account's webhook secret in the Relay console).

## Fix and escalation

Raise steady drift with the provider together with sample provider message ids. When receipts arrive and are accepted but events still go missing, find the receipt path that lost them and escalate to engineering.
