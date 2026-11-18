---
id: singleton-leaderless
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelaySingletonLeaderless]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 15
reversible: true
---

# Singleton task without a leader

## Symptom

`RelaySingletonLeaderless` pages with a `task` label: one of the database-led singleton tasks (`partition_maintenance`, `integrity_check`, `audit_checkpoint`, `audit_verify`, `audit_readback`, `retention_sweep`, `projection_rebuild`, `drr_dispatcher`, `load_shed_controller`, `kill_switch_paused_expiry`, `access_link_refresh`, `inbox_maintenance`, `webhook_maintenance` and the others in `config/config.exs`) has had no leader for five minutes. The node logs `singleton task has no leader` with the task name.

## Impact

Depends on the task. Every task keeps its progress in the database, so nothing is lost and a new leader continues where the last one stopped. While no node leads it, its work stops: `audit_checkpoint` stops checkpointing (the audit interval promise runs out), `partition_maintenance` stops creating partitions, `drr_dispatcher` stops fair dispatch, `kill_switch_paused_expiry` stops expiring paused deliveries. Every tenant of the installation is affected by the missing task.

## Diagnosis

Lease state of every task, newest change first:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT name, leader_node, lease_until, lease_until < now() AS expired, fencing_token, updated_at FROM relay.singleton_tasks ORDER BY lease_until NULLS FIRST"
```

`expired = t` on the alerting task means no node renewed the lease. `leader_node` is `<host>/<instance>`: the host part is the pod or machine that last led it.

Which nodes run the `worker` role (leadership runs only there):

```sh
kubectl get pods -l app.kubernetes.io/name=relay -L relay.suiss.app/node -o wide
```

```sh
$RELAY_EXEC printenv RELAY_ROLES
```

Whether the node reaches PostgreSQL at all:

```sh
curl -fsS "$RELAY_URL/readyz"
```

Lease errors in the node logs: `singleton lease unavailable` (the node cannot reach the database to take the lease) or `singleton task step failed` (it leads but the step fails).

## Decision tree

```text
task has no leader
├── no running pod has worker in RELAY_ROLES
│   └── start or scale a worker node (Mitigation 1)
├── worker pods run, /readyz fails or logs say "singleton lease unavailable"
│   └── database or maintenance pool problem: follow postgres-failover.md
├── worker pods run and are ready, logs say "singleton task step failed"
│   └── the task leads but fails; read the error code, restart the leader pod (Mitigation 2)
└── everything looks healthy
    └── restart one worker pod (Mitigation 2) and watch the lease row
```

## Mitigation

1. Scale the worker nodes back up (Kubernetes example: the Helm chart names each deployment `<release>-<node group>`, `relay-all` with the default values; use the node group that has `worker` in its roles):

```sh state-changing
kubectl scale deploy/relay-all --replicas=3
```

2. Restart the worker that last held the lease, so another worker takes it at once (the pod name is the host part of `leader_node`):

```sh state-changing
kubectl delete pod relay-7c9d8b6f5-abcde
```

Re-run the lease query: `lease_until` of the task should be in the future again within a minute and the alert clears.

## Fix and escalation

Find why the worker lost the lease: a crash loop, a maintenance pool (`MAINT_DATABASE_URL`) that cannot connect, or a node started without `worker` in `RELAY_ROLES`. If the task is `audit_checkpoint` and the gap is longer than the declared checkpoint interval, also follow `audit-checkpoint.md`. Escalate to the Relay engineering on-call when a task fails every step with the same error code.
