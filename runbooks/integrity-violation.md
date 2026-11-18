---
id: integrity-violation
kind: alert
severity: SEV2
channels: [all]
tenant_scope: some
alerts: [RelayIntegrityViolation]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Integrity check violation

## Symptom

`RelayIntegrityViolation` pages with `check` and `table` labels: the nightly `integrity_check` task found orphan records, a broken foreign key or stream key reference, or a partition table short of its horizon. The node logs `integrity check violation` with the check, the table and the count.

## Impact

Rows exist that reference something missing, or tenant-scoped rows lack their tenant. Reads that join them can return incomplete results or fail; tenant isolation may be affected if a row has no tenant. The count tells how many rows. The data is still there: nothing is deleted.

## Diagnosis

The report of the last run (saved in the task state):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT updated_at, jsonb_pretty(state) FROM relay.singleton_tasks WHERE name = 'integrity_check'"
```

Each entry under `violations` has `check`, `table` and `violations` (the count).

Run the checks again now, read-only:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT * FROM relay_ops.orphan_check() WHERE violations > 0"
```

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT * FROM relay_ops.reference_check() WHERE violations > 0"
```

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT * FROM relay_ops.partition_horizon() WHERE NOT ok"
```

Empty results mean the violation is gone (for example a transaction finished after the nightly run); a count that grows between runs means a writer still produces broken rows.

Recent deploys and migrations, since a new write path is the usual cause:

```sh
psql "$PG_ADMIN_URL" -c "SELECT version, inserted_at FROM public.schema_migrations ORDER BY inserted_at DESC LIMIT 5"
```

## Decision tree

```text
integrity violation
├── check = partition_horizon
│   └── follow partition-horizon.md
├── re-run returns no rows
│   └── transient; keep the alert open until the next nightly run is clean
├── re-run shows the same count
│   └── old broken rows: find the writer from the table and the deploy history
└── re-run shows a growing count
    └── a live writer bypasses the database functions: roll back the last deploy
```

## Mitigation

Never repair by deleting rows: Relay does not delete physically, and the rows are evidence of the bug. When the count grows after a deploy, roll back that deploy (Helm example, previous revision):

```sh state-changing
helm rollback relay
```

## Fix and escalation

Escalate to the Relay engineering on-call with the check name, table and counts. The fix is a code change in the writer that skipped the `relay_fn` write function, plus a reviewed data correction through a migration if one is needed. If the check concerns rows without a tenant, treat it as a possible isolation breach and raise to SEV1.
