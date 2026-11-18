---
id: postgres-vacuum
kind: alert
severity: SEV3
channels: [all]
tenant_scope: all
alerts: [RelayPostgresDeadTuples]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Dead rows piling up

## Symptom

`RelayPostgresDeadTuples` fires when more than 20% of the rows of a table or leaf partition have been dead for 30 minutes.

## Impact

Scans of the table slow down: the job queue and the hot ledger leaves are the most sensitive, and queue delay grows before anything fails.

## Diagnosis

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT schemaname, relname, n_live_tup, n_dead_tup, last_autovacuum, last_vacuum FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10"
psql "$MAINT_DATABASE_URL" -c "SELECT pid, relid::regclass, phase, heap_blks_scanned, heap_blks_total FROM pg_stat_progress_vacuum"
```

## Decision tree

```text
1. A long transaction holds back vacuum: follow `postgres-long-transaction`.
2. Autovacuum runs but cannot keep up: vacuum the table now and tune its per-leaf settings.
3. Autovacuum never runs on it: check `autovacuum` and the table's storage parameters.
```

## Mitigation

```sh state-changing
psql "$PG_ADMIN_URL" -c "VACUUM (VERBOSE, ANALYZE) $TABLE"
```

## Fix and escalation

Set the leaf's autovacuum parameters from measurement; new leaves copy them from the newest leaf of the table. Escalate to the database owner on call if the ratio keeps rising after a vacuum.
