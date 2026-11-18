---
id: postgres-pool-rule
severity: SEV3
channels: [all]
tenant_scope: installation
alerts: [RelayPoolRuleExceeded]
last_tested: 2026-11-18
tested_by: none
automation: 0
eta_minutes: 60
reversible: true
---

# Connection demand over the pooling rule

## Symptom

`RelayPoolRuleExceeded` fires when a node computed at boot that `nodes × pool × 2` exceeds half of the server's `max_connections` and no PgBouncer is configured (`RELAY_DATABASE_POOLER=none`). The node logged a warning with the demand and the budget.

## Impact

A rollout that runs old and new nodes side by side, or a scale-out, can exhaust the server's connections; requests then wait for a connection and are shed with `503`.

## Diagnosis

```sh
psql "$ADMIN_DATABASE_URL" -c "SHOW max_connections"
psql "$ADMIN_DATABASE_URL" -c "SELECT usename, count(*) FROM pg_stat_activity GROUP BY 1 ORDER BY 2 DESC"
```

Compare `RELAY_NODE_COUNT` and `POOL_SIZE` with the actual node count.

## Decision tree

1. `RELAY_NODE_COUNT` is wrong: correct it.
2. Nodes autoscale or the count is right: put a transaction-mode PgBouncer in front of PostgreSQL.
3. Pool waits are already shedding requests: do not grow the pool; that only moves the queue into PostgreSQL.

## Mitigation

Enable the chart's PgBouncer and point the database URLs at it:

```sh state-changing
helm upgrade relay deploy/helm/relay --reuse-values --set pgbouncer.enabled=true --set pgbouncer.databaseHost="$DATABASE_HOST"
```

## Fix and escalation

Keep the rule true at the planned maximum node count. Escalate to the database owner on call if `max_connections` is the real limit.
