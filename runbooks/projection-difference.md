---
id: projection-difference
kind: alert
severity: SEV2
channels: [all]
tenant_scope: some
alerts: [RelayProjectionDifference]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Delivery projection differs from its ledger

## Symptom

`RelayProjectionDifference` pages: the weekly `projection_rebuild` task recomputed a delivery's projection (its row in `relay.deliveries`) from its ledger (`relay.delivery_events`) and they differ. The node logs `delivery projection differs from its ledger` with the delivery id and the differing columns, and at the end of the sweep `projection rebuild found differences` with the count.

## Impact

The ledger is the truth; the projection is what the API, the console, webhooks and reports show. For the affected deliveries tenants may see a wrong status (for example `delivered` when the ledger says `failed`). Nothing is resent, and no data is lost. The count tells how many deliveries.

## Diagnosis

The sweep's totals and where it stopped:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT leader_node, updated_at, jsonb_pretty(state) FROM relay.singleton_tasks WHERE name = 'projection_rebuild'"
```

`last_sweep` has `checked` and `differing`; `finished_at` is when the last sweep ended.

For a delivery id from the log line, its projection and its ledger:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT id, tenant_id, environment, channel, provider, decision, accepted_at, delivered_at, failure_kind, failure_class FROM relay.deliveries WHERE id = '01890000-0000-7000-8000-000000000000'"
```

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT received_at, occurred_at, actor, event_type, raw_code, provider, attempt_no, projection_result FROM relay.delivery_events WHERE delivery_id = '01890000-0000-7000-8000-000000000000' ORDER BY occurred_at, received_at"
```

Events with `projection_result = conflict_flagged` or `stale_ignored` show where the projection and the ledger parted. A projection change with no matching ledger row means a write path updated the projection directly.

## Decision tree

```text
projection differs
├── differing deliveries share one channel or provider
│   └── a receipt or reconciliation path of that provider: check recent deploys of it
├── differing deliveries all after one deploy
│   └── roll back that deploy (Mitigation)
├── differing columns are only timestamps
│   └── SEV3: ordering bug, no visible status change; open a ticket
└── isolated, old deliveries
    └── keep the ids for the fix; the ledger already holds the truth
```

## Mitigation

The ledger wins and is never edited. When differences started with a deploy, roll it back so no new ones appear (Helm example):

```sh state-changing
helm rollback relay
```

Tell the tenants whose deliveries are affected (their ids are in the logs) that the shown status may be wrong, through the account team, not through Relay.

## Fix and escalation

Escalate to the Relay engineering on-call with the delivery ids and differing columns. The fix is a code change in the path that changed the projection without a ledger row, followed by a migration that recomputes the affected projections from the ledger. The next weekly sweep must report `differing: 0`.
