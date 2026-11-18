---
id: proven-delivery-drop
kind: alert
severity: SEV1
channels: [all]
tenant_scope: some
alerts: [RelayProvenDeliveryDrop]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Proven delivery drop

## Symptom

On a channel and provider, the share of provider-accepted deliveries that later got a delivery proof (`relay:delivery_proven:ratio_1h`, from `relay_funnel_total{stage="delivered"}` over `stage="provider_accepted"`) fell by more than 40% compared with the hour before, with at least 200 accepted deliveries in both hours. The acceptance SLOs may all be green.

## Impact

Treat it as users receiving nothing until receipts prove otherwise: the provider takes the messages, but either they do not arrive (account suspended, spam folder, carrier filtering, dead tokens) or the delivery receipts stopped coming back. Either way every tenant on that channel and provider is affected. SEV1 until the receipt path is shown to be the only problem; SEV2 after that.

## Diagnosis

Ratio now and an hour ago, per channel and provider:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay:delivery_proven:ratio_1h' | jq '.data.result[] | {channel: .metric.channel, provider: .metric.provider, ratio: .value[1]}'
```

Whether provider events still arrive at all (0 means the receipt path is silent):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (channel, provider) (increase(relay_provider_event_total[1h]))' | jq '.data.result'
```

Receipts recorded in the last hour by provider and state (`rejected` receipts failed verification):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT provider, state, count(*), max(received_at) FROM relay.webhook_receipts WHERE received_at > now() - interval '1 hour' GROUP BY 1, 2 ORDER BY 1, 2"
```

What the delivery events say, by type and raw code:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT provider, event_type, raw_code, count(*) FROM relay.delivery_events WHERE received_at > now() - interval '1 hour' AND event_type IN ('provider.reported', 'attempt.failed') GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 20"
```

## Decision tree

```text
proven delivery ratio dropped on channel/provider P
├── no provider events at all in the last hour
│   ├── receipts rejected -> webhook signing secret changed: fix the provider webhook credential
│   └── no receipts -> provider stopped calling /inbound/v1/providers/{id}: check the provider console subscription
│       (email: esp-events.md)
├── events arrive, failure/bounce codes rose
│   ├── one sender or list -> stop that campaign (Mitigation)
│   └── all senders -> provider account suspended or reputation hit: provider console, provider-incident.md
└── events arrive, nothing abnormal
    └── provider delays receipts: reconciliation-lag.md
```

## Mitigation

When one campaign or workflow causes the bounces, stop it so it does not damage the sender reputation further (marketing first):

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"proven delivery drop\", ttl: \"2h\", scope: :campaign, scope_ref: \"cmp_REPLACE\", tenant: \"ten_REPLACE\", environment: :live))"
```

When the provider account itself is suspended, fail over to the fallback provider in the console route editor. A suspended provider account is SEV1 on its own.

## Fix and escalation

Restore the receipt path (subscription, signing secret) or the account standing with the provider. Reconciliation fills receipt gaps afterwards. Escalate to the provider's support and, for e-mail reputation, to whoever owns the sending domains.
