---
id: audit-checkpoint
kind: alert
severity: SEV1
channels: [none]
tenant_scope: all
alerts: [RelayAuditCheckpointOverdue, RelayAuditCheckpointUnpublished]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Audit checkpoint overdue or unpublished

## Symptom

- `RelayAuditCheckpointOverdue`: an audit record was bound into the Merkle log later than the declared checkpoint interval. The node logs `audit record integrated after the declared checkpoint interval`.
- `RelayAuditCheckpointUnpublished`: a signed checkpoint reached none of the configured publication targets (`worm_store`, `siem`, `customer:<id>`). The node logs `audit checkpoint reached no publication target` with the log origin.

## Impact

No message delivery is affected. The audit log's integrity promise is: every record is covered by a signed checkpoint, published outside Relay, within the declared interval. Overdue or unpublished checkpoints break that promise for every tenant of the installation, and the interval is published to customers, so this is a security event even when nothing was tampered with.

## Diagnosis

The checkpoint task's lease and saved state:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT leader_node, lease_until, updated_at FROM relay.singleton_tasks WHERE name = 'audit_checkpoint'"
```

An expired lease means no node runs the task: follow `singleton-leaderless.md`.

The newest checkpoints per log and when they were made:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT log_origin, max(tree_size) AS tree_size, max(created_at) AS newest FROM relay.audit_checkpoints GROUP BY log_origin ORDER BY newest DESC"
```

A `newest` older than the interval with records still arriving means the task does not sign: usually the key store.

Publication outcomes of the last hour, per target:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT target, status, count(*), max(created_at) AS last, max(detail) FILTER (WHERE status = 'failed') AS last_error FROM relay.audit_checkpoint_publications WHERE created_at > now() - interval '1 hour' GROUP BY target, status ORDER BY target"
```

Only `failed` rows for every target means the publication side is broken; `last_error` names why (credentials, bucket, network).

Whether the key store answers on the node:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Keys.ping())'
```

## Decision tree

```text
checkpoint overdue or unpublished
├── audit_checkpoint lease expired
│   └── follow singleton-leaderless.md
├── Relay.Keys.ping() is not :ok
│   └── key store down: follow push-signing-unavailable.md (same key store), then re-check
├── checkpoints are recent but publications all failed
│   ├── object store / SIEM unreachable or credentials rejected
│   │   └── restore the target (Mitigation); the next checkpoint publishes
│   └── one target failing, another published
│       └── RelayAuditCheckpointUnpublished does not fire; open a ticket for that target
└── checkpoints recent and published, overdue alert fired once
    └── a slow step (large backlog after an outage); confirm it does not repeat
```

## Mitigation

Restore the failing dependency (key store, object store credentials, SIEM endpoint) in its own console. Relay has no command that publishes an old checkpoint again by hand: the task signs a new checkpoint (or a heartbeat of the same tree) at least every minute and publishes it, and that checkpoint covers every older record. If the leader is stuck, restart it so another worker takes the task:

```sh state-changing
kubectl delete pod relay-7c9d8b6f5-abcde
```

Confirm with the publications query that a `published` row arrived for an independent target.

## Fix and escalation

Treat it as a security incident: declare an incident (see `incident/`), keep the node logs of the gap, and record how long records waited. Escalate to the security owner of the installation; if customers are promised the interval contractually, the communication lead informs them through the status page, not through Relay.
