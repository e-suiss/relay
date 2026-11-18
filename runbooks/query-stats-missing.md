---
id: query-stats-missing
kind: alert
severity: SEV4
channels: [none]
tenant_scope: none
alerts: [RelayQueryStatsMissing]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# PostgreSQL query statistics missing

## Symptom

`RelayQueryStatsMissing` (warning) fires: a node checked at start that PostgreSQL preloads `pg_stat_statements` and found it does not. The node logs `postgres does not collect query statistics; preload pg_stat_statements`.

## Impact

Nothing fails. Query statistics are missing, so slow queries and query budget breaches cannot be traced to a statement. Every later performance investigation is blind until it is fixed.

## Diagnosis

What PostgreSQL preloads:

```sh
psql "$PG_ADMIN_URL" -c "SHOW shared_preload_libraries"
```

`pg_stat_statements` must be in the list.

The exact check the node runs:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_settings WHERE name = 'pg_stat_statements.max')"
```

`t` means the module is loaded now; the alert then reflects an older node start.

Run the node's check again:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Platform.Store.query_stats_check())'
```

`:ok` means the module is loaded; `{:error, :query_stats_missing}` means it is not.

## Decision tree

```text
query stats missing
├── SHOW shared_preload_libraries lacks pg_stat_statements
│   └── add it and restart PostgreSQL in a maintenance window (Fix)
└── the library is loaded now
    └── the gauge comes from a node started before the fix: restart the nodes (Mitigation)
```

## Mitigation

Nothing urgent. When the library is already loaded, restart the nodes one at a time so the gauge clears (Kubernetes example):

```sh state-changing
kubectl rollout restart deploy/relay-all
```

## Fix and escalation

Add `pg_stat_statements` to `shared_preload_libraries` (the Helm values list it under `database.serverRequirements.sharedPreloadLibraries`; the compose file passes it on the command line), restart PostgreSQL in a planned window, and run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` as the database administrator. A managed database sets it in its parameter group. No escalation is needed unless the database provider refuses the library.
