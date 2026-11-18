---
id: postgres-xid-age
severity: SEV2
channels: [all]
tenant_scope: installation
alerts: [RelayPostgresXidAge, RelayPostgresXidAgeCritical]
last_tested: 2026-11-18
tested_by: none
automation: 0
eta_minutes: 60
reversible: true
---

# Transaction ID age climbing

## Symptom

`RelayPostgresXidAge` fires above 600 million, `RelayPostgresXidAgeCritical` above one billion transactions since the oldest unfrozen transaction ID.

## Impact

Nothing yet. Near two billion PostgreSQL stops accepting writes to prevent wraparound, which stops the whole installation.

## Diagnosis

```sh
psql "$ADMIN_DATABASE_URL" -c "SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC"
psql "$ADMIN_DATABASE_URL" -c "SELECT c.oid::regclass, age(c.relfrozenxid) FROM pg_class c WHERE c.relkind IN ('r', 't', 'm') ORDER BY 2 DESC LIMIT 10"
psql "$ADMIN_DATABASE_URL" -c "SELECT slot_name, xmin, catalog_xmin FROM pg_replication_slots"
```

## Decision tree

1. A long open transaction or a prepared transaction holds the horizon: follow `postgres-long-transaction`.
2. A slot with an old `xmin` holds it: follow `postgres-replication-slot`.
3. Autovacuum cannot keep up on the oldest tables: run a manual freeze on them.

## Mitigation

Freeze the oldest table found above, one at a time:

```sh state-changing
psql "$ADMIN_DATABASE_URL" -c "VACUUM (FREEZE, VERBOSE) $TABLE"
```

## Fix and escalation

Remove what held the horizon and raise autovacuum throughput for the tables that lag (per-leaf settings, measured). Escalate to the database owner on call at the critical threshold.
