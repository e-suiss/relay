---
id: duplicate-delivery
kind: alert
severity: SEV2
channels: [all]
tenant_scope: some
alerts: [RelayDuplicateDelivery]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 45
reversible: true
---

# Duplicate deliveries and conflicts

## Symptom

More than 1% of a channel and provider's provider-accepted deliveries in the last hour were counted as `duplicate_delivered` or `conflict` (`relay_delivery_anomaly_total{kind}`). A duplicate is a second attempt of the same delivery that the provider also delivered; a conflict is provider evidence that contradicts what the ledger already holds.

## Impact

Recipients may have received the same message twice (duplicates), or delivery states shown to tenants may be wrong (conflicts). Two one-time codes or two payment notices confuse users. SEV2; SEV1 when `security` or `transactional` messages are duplicated at scale.

## Diagnosis

Anomaly ratio by kind, channel and provider:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (kind, channel, provider) (increase(relay_delivery_anomaly_total[1h]))' | jq '.data.result'
```

Deliveries of the last hour flagged in the projection:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT channel, provider, count(*) FILTER (WHERE duplicate_delivered) AS duplicates, count(*) FILTER (WHERE has_conflict) AS conflicts FROM relay.deliveries WHERE created_at > now() - interval '2 hours' GROUP BY 1, 2 HAVING count(*) FILTER (WHERE duplicate_delivered OR has_conflict) > 0"
```

For duplicates, whether the extra attempts followed uncertain outcomes (`unknown` attempt state) and whether they reused the provider idempotency key:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT a.provider, a.state, count(*), count(DISTINCT a.provider_idempotency_key) AS keys FROM relay.delivery_attempts a JOIN relay.deliveries d ON d.tenant_id = a.tenant_id AND d.environment = a.environment AND d.id = a.delivery_id WHERE d.duplicate_delivered AND d.created_at > now() - interval '2 hours' GROUP BY 1, 2"
```

As many keys as attempts means the retries were sent with new keys, so the provider could not drop them; equal keys with duplicates means the provider ignores its idempotency key.

## Decision tree

```text
anomaly ratio above 1% on channel/provider P
├── kind duplicate_delivered
│   ├── preceded by unknown attempts, keys differ -> retry path lost the key: engineering bug
│   ├── keys equal -> provider does not honour idempotency: provider case, review retry policy
│   └── started after a deploy -> roll back
└── kind conflict
    ├── provider sends contradicting receipts (e.g. delivered then failed) -> provider case
    └── after a change in the evidence data set -> review the data set version
```

## Mitigation

When duplicates come from one campaign's retries and keep growing, stop that campaign while the cause is found:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"duplicate deliveries\", ttl: \"2h\", scope: :campaign, scope_ref: \"cmp_REPLACE\", tenant: \"ten_REPLACE\", environment: :live))"
```

When a deploy introduced it, roll it back:

```sh state-changing
kubectl rollout undo deploy/relay-all
```

Conflicts need no stop: the ledger keeps every piece of evidence and the projection follows its rules.

## Fix and escalation

Duplicates are visible to recipients: fix the retry path or the provider's idempotency handling, and write a postmortem when `security` or `transactional` messages were duplicated. Escalate provider-side idempotency problems to the provider with sample attempt keys.
