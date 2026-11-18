---
id: postgres-disk
severity: SEV2
channels: [all]
tenant_scope: installation
alerts: [RelayPostgresDiskHigh, RelayPostgresDiskCritical]
last_tested: 2026-11-18
tested_by: none
automation: 0
eta_minutes: 30
reversible: true
---

# PostgreSQL volume filling up

## Symptom

`RelayPostgresDiskHigh` (more than 70% used for 10 minutes) or `RelayPostgresDiskCritical` (more than 85% used for 5 minutes) fires for a PostgreSQL data or WAL volume.

## Impact

None yet at 70%. A full volume stops every write: the API answers `503`, no job can be queued or finished, and the audit log stops. A full WAL volume can stop the primary and its standbys.

## Diagnosis

Find what grows: WAL kept for a slot or for failed archiving, a table or its indexes, or temporary files.

```sh
psql "$ADMIN_DATABASE_URL" -c "SELECT slot_name, active, wal_status, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS kept FROM pg_replication_slots"
psql "$ADMIN_DATABASE_URL" -c "SELECT last_failed_wal, last_failed_time, last_archived_time FROM pg_stat_archiver"
psql "$ADMIN_DATABASE_URL" -c "SELECT n.nspname, c.relname, pg_size_pretty(pg_total_relation_size(c.oid)) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 15"
```

## Decision tree

1. A slot keeps most of the WAL: follow `postgres-replication-slot`.
2. The archiver fails and WAL piles up: follow `postgres-archiver`.
3. A table grew past its plan: check that partition detach runs (`RelayPartitionHorizon`, partition maintenance task) and that dead rows are vacuumed (`postgres-vacuum`).
4. Growth is real data: grow the volume.

## Mitigation

Grow the volume online; never delete files under `pg_wal` by hand. On Kubernetes with an expandable storage class:

```sh state-changing
kubectl patch pvc "$PVC" -p '{"spec":{"resources":{"requests":{"storage":"'"$NEW_SIZE"'"}}}}'
```

## Fix and escalation

Remove the cause found in the decision tree, then size the volume for the retention plan with headroom so that it stays under 70%. Escalate to the database owner on call if the volume cannot be grown or the critical alert does not clear within 30 minutes.
