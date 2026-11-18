---
id: archive-failure
kind: procedure
severity: SEV3
channels: [all]
tenant_scope: all
alerts: []
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Archive failure

## Symptom

Partitions whose hot retention has passed are not leaving the database: the list of partitions due for archive grows, detached tables pile up waiting for the archive role, a detach stays interrupted, or the database disk grows faster than the traffic explains.

## Impact

No message is lost and nothing stops at first: archiving is what keeps the hot database small. A growing backlog means a growing disk, slower vacuums and longer backups; on a full disk PostgreSQL stops accepting writes, which is SEV1. Detached tables still hold personal data until they are archived and dropped, so retention promises slip while the backlog exists.

## Diagnosis

Partitions past their hot retention, oldest first:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT table_name, partition_name, upper_bound FROM relay_ops.partition_due_for_archive() ORDER BY upper_bound LIMIT 20"
```

A few rows are normal (the maintenance task detaches one partition per step); a list that only grows means detaching stopped.

Detaches that were interrupted (the next maintenance step finishes them):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT parent.relname AS table_name, child.relname AS partition_name FROM pg_inherits i JOIN pg_class child ON child.oid = i.inhrelid JOIN pg_class parent ON parent.oid = i.inhparent JOIN pg_namespace n ON n.oid = parent.relnamespace WHERE n.nspname = 'relay' AND i.inhdetachpending"
```

Detached tables handed to the archive role and not yet archived:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT state->'detached' AS detached, updated_at FROM relay.singleton_tasks WHERE name = 'partition_maintenance'"
```

How much disk the backlog takes:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT c.relname, pg_size_pretty(pg_total_relation_size(c.oid)) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'relay' AND c.relkind = 'r' AND NOT c.relispartition AND c.relname ~ '_p[0-9]' ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 20"
```

## Decision tree

```text
archive backlog grows
├── partition_maintenance has no leader -> singleton-leaderless.md
├── interrupted detaches present and not finishing
│   └── a long transaction blocks DETACH ... FINALIZE: partition-horizon.md
│       (same lock diagnosis), then wait one step
├── detached list grows, archive step not removing tables
│   ├── object store unreachable or credentials expired -> fix the target
│   └── archive copy fails verification -> keep the table, escalate
└── disk above 80%
    └── raise the volume first (Mitigation), then work the backlog
```

## Mitigation

The first goal is disk headroom; the backlog can be worked off afterwards. Grow the database volume (Kubernetes example; managed databases have their own storage setting):

```sh state-changing
kubectl patch pvc data-postgres-0 -p '{"spec":{"resources":{"requests":{"storage":"500Gi"}}}}'
```

Never drop a detached table by hand: a table is removed only after its archive copy is written and verified, and the database never deletes rows outside that path.

## Fix and escalation

Fix the cause the decision tree found and watch the due list shrink by one partition per maintenance step (every 15 minutes). Escalate to the database owner when the disk passes 85 % or a detach stays interrupted for more than an hour, and to the security and compliance lead when retention dates are missed by more than a week.
