---
id: postgres-long-transaction
severity: SEV2
channels: [all]
tenant_scope: installation
alerts: [RelayPostgresLongTransaction, RelayPostgresLongTransactionCritical]
last_tested: 2026-11-18
tested_by: none
automation: 0
eta_minutes: 15
reversible: false
---

# Long open PostgreSQL transaction

## Symptom

`RelayPostgresLongTransaction` fires when a client transaction has been open for more than 5 minutes, `RelayPostgresLongTransactionCritical` for more than 30 minutes.

## Impact

An open transaction holds back vacuum on every table, so dead rows and bloat grow on the queue and ledger tables, and the transaction ID age climbs. Its locks can block migrations and partition maintenance.

## Diagnosis

```sh
psql "$ADMIN_DATABASE_URL" -c "SELECT pid, usename, application_name, state, now() - xact_start AS age, left(query, 120) FROM pg_stat_activity WHERE xact_start IS NOT NULL ORDER BY xact_start LIMIT 10"
```

Note the login: `relay_report` is a report or export, `relay_maint` a maintenance task, `relay_worker` or `relay_queue` application work, anything else a person or a tool.

## Decision tree

1. A report or export that is still making progress: let it finish if it ends before the critical threshold, otherwise cancel it.
2. `idle in transaction`: the client forgot the transaction; terminate the backend.
3. A migration or maintenance task: check its log before acting; a detach that is cancelled is completed by the next maintenance step.

## Mitigation

Cancel the statement first; terminate the backend only if cancelling does not end the transaction.

```sh state-changing
psql "$ADMIN_DATABASE_URL" -c "SELECT pg_cancel_backend($PID)"
```

```sh state-changing
psql "$ADMIN_DATABASE_URL" -c "SELECT pg_terminate_backend($PID)"
```

## Fix and escalation

Find the code path or tool that left the transaction open and fix it; Relay never calls the network inside a transaction. Escalate to the database owner on call if the transaction cannot be ended.
