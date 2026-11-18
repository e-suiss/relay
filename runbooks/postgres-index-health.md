---
id: postgres-index-health
kind: alert
severity: SEV4
channels: [all]
tenant_scope: all
alerts: [RelayPostgresIndexBloat, RelayPostgresInvalidIndex]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Index bloat or an invalid index

## Symptom

`RelayPostgresIndexBloat` opens a ticket when an index is estimated to be more than half bloat for 6 hours; `RelayPostgresInvalidIndex` when an invalid index has been there for an hour.

## Impact

A bloated index costs memory and I/O on every write and lookup. An invalid index is maintained on every write but never used, and a unique one does not enforce uniqueness.

## Diagnosis

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT n.nspname, c.relname, pg_size_pretty(pg_relation_size(c.oid)) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE NOT i.indisvalid"
psql "$MAINT_DATABASE_URL" -c "SELECT schemaname, relname, indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) FROM pg_stat_user_indexes ORDER BY pg_relation_size(indexrelid) DESC LIMIT 15"
```

## Decision tree

```text
1. An invalid index after a failed migration step: rebuild it concurrently, or let the migration that created it run again.
2. A bloated index on a leaf that is detached soon: leave it.
3. A bloated index on a live table: rebuild it concurrently.
```

## Mitigation

```sh state-changing
psql "$PG_ADMIN_URL" -c "REINDEX INDEX CONCURRENTLY $INDEX"
```

## Fix and escalation

Find why the build failed or why the index bloats (update pattern, missed vacuum) and fix it. No escalation is needed unless a unique index stays invalid.
