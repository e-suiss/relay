---
id: esp-events
kind: alert
severity: SEV2
channels: [email]
tenant_scope: some
alerts: [RelayEspEventDelay, RelayEspEventsSilent]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# E-mail provider events late or silent

## Symptom

- `RelayEspEventDelay`: the 95th percentile of the time from handoff to an e-mail provider's delivery event (`relay_provider_event_delay_seconds`) is above 30 minutes.
- `RelayEspEventsSilent`: an e-mail provider accepted more than 100 messages in an hour and sent no delivery event at all (`relay_provider_event_total{channel="email"}`).

## Impact

Delivery, bounce and complaint events do not reach Relay: bounces are not suppressed, complaints are not honoured in time, and tenants see e-mails stuck at accepted. A provider account that was suspended often still answers the send API, so silence can also mean nothing is delivered. SEV2; SEV1 when the account turns out to be suspended.

## Diagnosis

Event delay and event volume per provider:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=histogram_quantile(0.95, sum by (provider, le) (rate(relay_provider_event_delay_seconds_bucket{channel="email"}[30m])))' | jq '.data.result'
```

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (provider) (increase(relay_provider_event_total{channel="email"}[1h]))' | jq '.data.result'
```

Provider webhook receipts of the last two hours (`rejected` means the signature check failed):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT provider, state, count(*), max(received_at) FROM relay.webhook_receipts WHERE received_at > now() - interval '2 hours' GROUP BY 1, 2 ORDER BY 1, 2"
```

Receipts stuck in `received` (stored but not processed) point at Relay's intake, not the provider:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT provider, count(*), min(received_at) FROM relay.webhook_receipts WHERE state = 'received' GROUP BY 1"
```

Whether the provider's inbound endpoint answers (any status but a connection error means Relay is reachable; replace the account id):

```sh
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$RELAY_URL/inbound/v1/providers/PROVIDER_ACCOUNT_ID"
```

## Decision tree

```text
e-mail events late or silent for provider P
├── no receipts at all
│   ├── endpoint unreachable from outside -> ingress/TLS problem: fix routing
│   └── endpoint reachable -> provider stopped sending: check the webhook subscription in P's console
├── receipts rejected -> signing secret changed: update the provider account's webhook secret in the console
├── receipts stuck in received -> intake jobs not running: queue-oldest-job.md
└── receipts arrive late -> P delays its events: check P's status page; reconciliation fills the gap
```

## Mitigation

Check the account standing in the provider's console first: a suspended account needs a fallback route at once (console route editor) and is SEV1. When the subscription or the signing secret is the cause, restore it in the provider console and in the provider account's settings in the console; no Relay command is needed. Restoring the intake is enough: reconciliation fills the events that were missed.

## Fix and escalation

Escalate to the provider's support when events are delayed on their side. Keep the subscription and secret rotation in the tenant's provider change checklist. When the intake jobs are stuck, follow queue-oldest-job.md and escalate to engineering.
