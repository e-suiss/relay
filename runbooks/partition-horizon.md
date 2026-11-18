---
id: partition-horizon
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelayPartitionHorizon]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 20
reversible: true
---

# Partition horizon

## Symptom

`RelayPartitionHorizon` pages: a partitioned table (`delivery_events`, `delivery_attempts`, `audit_log` and the other tables in `relay.partition_policies`) has fewer premade partitions ahead of now than its alarm threshold. The `partition_maintenance` singleton task creates them every 15 minutes, so the task has stopped or its DDL keeps hitting the lock timeout.

## Impact

Nothing fails yet. Once time passes the furthest partition bound, every insert into that table fails, which stops acceptance, delivery and auditing for every tenant of the installation at once. The threshold leaves days, not minutes; act within the working day.

## Diagnosis

Which tables are short, and how far ahead their last partition reaches:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT table_name, furthest_bound, ok FROM relay_ops.partition_horizon() ORDER BY furthest_bound NULLS FIRST"
```

Rows with `ok = f` are the ones alerting; `furthest_bound` is when inserts start to fail. A `NULL` bound means the table has no partitions at all, which only happens on a broken install.

Who leads the task and when it last saved its state:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT name, leader_node, lease_until, updated_at, state FROM relay.singleton_tasks WHERE name = 'partition_maintenance'"
```

A `lease_until` in the past means no node leads it: follow `singleton-leaderless.md`. A fresh `updated_at` while the horizon does not move means it runs but its DDL hits the lock timeout (the leader logs `partition create failed` with the table).

Long transactions that hold locks on the parent tables:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT pid, now() - xact_start AS age, state, left(query, 80) AS query FROM pg_stat_activity WHERE xact_start < now() - interval '5 minutes' ORDER BY xact_start"
```

## Decision tree

```text
partition_horizon() has ok = f
├── singleton_tasks.lease_until in the past
│   └── no leader: follow singleton-leaderless.md, then re-check
├── updated_at fresh, horizon not moving
│   ├── a transaction older than 5 minutes exists
│   │   └── end that transaction (Mitigation 1), wait one step (15 min)
│   └── no long transaction
│       └── restart the leader node (Mitigation 2)
└── updated_at stale but lease held
    └── restart the leader node (Mitigation 2)
```

## Mitigation

1. End the transaction that blocks the DDL (find the `pid` with the query above; prefer asking its owner first):

```sh state-changing
psql "$PG_ADMIN_URL" -c "SELECT pg_cancel_backend(12345)"
```

2. Restart the node that holds the lease so another node takes over and runs a step at once (Kubernetes example; the pod name is the part of `leader_node` before the slash):

```sh state-changing
kubectl delete pod relay-all-7c9d8b6f5-abcde
```

Re-run the first diagnosis query after the next step: every row should show `ok = t`.

## Fix and escalation

Find why the task stopped (lock timeouts from a migration or a long report, a node that never got leadership) and fix that cause. If the bound is less than a day away and the task still cannot create partitions, escalate to the database owner on call: an operator with the `relay_migrator` role can create the next partition by hand with `relay_private.partition_create`, which is what the task calls.
