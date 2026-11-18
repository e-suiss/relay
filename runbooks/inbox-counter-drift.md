---
id: inbox-counter-drift
kind: alert
severity: SEV3
channels: [in_app]
tenant_scope: some
alerts: [RelayInboxCounterDrift]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Inbox counter drift

## Symptom

`RelayInboxCounterDrift` (warning) fires: the nightly `inbox_maintenance` sweep found inbox counters (unseen, unread, total in `relay.inbox_counters`) that differed from the recipients' items, and fixed them. `relay_inbox_counter_drift_total{source="nightly"}` grew in the last day.

## Impact

Until the sweep fixed them, the affected recipients saw wrong badge counts in the inbox. Messages themselves were never wrong or missing. The counters are correct again; the alert asks for the cause, since a write path changes items without updating their counters.

## Diagnosis

How much drift, nightly against client reports, over the last week:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (source) (increase(relay_inbox_counter_drift_total[7d]))'
```

`source="report"` counts drift found when a client reported its counters inconsistent; both growing together means users notice it.

Client reports and how many needed a repair:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (result) (increase(relay_inbox_inconsistency_reports_total[1d]))'
```

The sweep's state and totals:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT leader_node, updated_at, jsonb_pretty(state) FROM relay.singleton_tasks WHERE name = 'inbox_maintenance'"
```

When the drift started, compared with deploys:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum(increase(relay_inbox_counter_drift_total{source="nightly"}[1d]))[14d:1d]'
```

## Decision tree

```text
counter drift found
├── first drift right after a deploy
│   └── the deploy's inbox write path (bulk operations, retire, mark read): roll back if it keeps growing
├── drift small and steady for weeks
│   └── a rare race; open a ticket with the counts
└── drift large (thousands) in one night
    └── raise to SEV2: users see wrong badges every day until the bug is fixed
```

## Mitigation

The nightly sweep already fixes drifted counters, and a client's report repairs that subscriber at once, so no manual repair is needed. When drift grew after a deploy and keeps growing, roll back that deploy (Helm example):

```sh state-changing
helm rollback relay
```

## Fix and escalation

Escalate to the Relay engineering on-call with the counts and the deploy that preceded the first drift. The fix is a code change so that every item change updates its counters in the same transaction.
