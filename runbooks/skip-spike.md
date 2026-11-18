---
id: skip-spike
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelaySkipSpike]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Skip spike

## Symptom

`RelaySkipSpike` fires: on one channel, deliveries skipped by one `rule_id` rose to more than three times yesterday's rate over the last 30 minutes, with at least 50 skips. The `observability_rollup` task counts skips from the ledger once a minute and exports them as `relay_delivery_skipped_total{channel, rule_id}`.

## Impact

Skipped deliveries are not sent and are not retried. A skip is a decision, not an error: when the change behind it was intended (a tenant tightened preferences, an import of refusals landed) nothing is wrong. When it was not intended, recipients silently stop receiving messages of that kind, for one tenant or for every tenant that shares the rule. A sudden rise of `consent.missing` or `iys.approval_missing` is usually a consent import that did not run.

## Diagnosis

Which rules and channels are rising now, against yesterday:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (channel, rule_id) (increase(relay_delivery_skipped_total[30m]))' | jq -r '.data.result[] | "\(.metric.channel) \(.metric.rule_id) \(.value[1])"'
```

The `rule_id` names the decision (`consent.missing`, `preference.channel`, `suppression.address`, `iys.stale`, `quiet_hours.deferred` …). Its meaning is in the rule dictionary data set under `priv/datasets/rule_dictionary/`.

Which tenants the skips come from (replace the rule and the channel):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, environment, count(*) FROM relay.deliveries WHERE decision = 'skip' AND decision_rule_id = 'consent.missing' AND channel = 'sms' AND created_at > now() - interval '1 hour' GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20"
```

One tenant dominating means a change of that tenant. Many tenants at once means a change of Relay (a deploy, a new rule dictionary or data set version) or of a shared input.

Recent changes of the inputs of that tenant (consents, refusals, suppressions, preferences):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT 'consents' AS source, count(*) FROM relay.consents WHERE tenant_id = '00000000-0000-0000-0000-000000000000' AND created_at > now() - interval '1 day' UNION ALL SELECT 'refusals', count(*) FROM relay.refusals WHERE tenant_id = '00000000-0000-0000-0000-000000000000' AND created_at > now() - interval '1 day' UNION ALL SELECT 'suppressions', count(*) FROM relay.suppressions WHERE tenant_id = '00000000-0000-0000-0000-000000000000' AND created_at > now() - interval '1 day' UNION ALL SELECT 'preference_changes', count(*) FROM relay.preference_changes WHERE tenant_id = '00000000-0000-0000-0000-000000000000' AND created_at > now() - interval '1 day'"
```

A burst in one of them that matches the rule explains the spike. A rule like `consent.missing` rising while `consents` shows no new rows for days points to an import that stopped.

## Decision tree

```text
RelaySkipSpike for (channel, rule_id)
├── one tenant dominates
│   ├── its inputs changed in the last day and the change matches the rule
│   │   └── intended: tell the tenant what it changed, close the alert
│   └── no matching input change, or an expected import is missing
│       └── tell the tenant; its import or integration is broken (Fix)
├── many tenants at once
│   ├── a deploy or a new data set version landed just before
│   │   └── treat as a Relay regression: escalate to the owning team, consider rollback
│   └── no deploy
│       └── a shared input (İYS copy, a provider's suppression feed): check iys-copy-stale.md
└── rule is quiet_hours.deferred or a digest rule
    └── deferrals, not losses: confirm the schedule change with the tenant
```

## Mitigation

Nothing to stop: skips send nothing. Do not lift suppressions or edit consents on the tenant's behalf; a skip that protects a recipient stays in place until the tenant fixes its input. If a Relay deploy caused the spike for many tenants, roll that deploy back through the normal release process.

## Fix and escalation

The tenant fixes its import, preference sync or consent integration; skipped deliveries are not replayed by Relay. A regression in Relay's policy lattice or rule dictionary goes to the delivery policy owners with the `rule_id`, the channel and the first minute the rate rose. If a skip reveals that messages went out that should have been skipped, that is a compliance incident: declare it as described in `incident/`.
