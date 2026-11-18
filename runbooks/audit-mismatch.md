---
id: audit-mismatch
kind: alert
severity: SEV1
channels: [none]
tenant_scope: all
alerts: [RelayAuditMismatch]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: false
---

# Audit verification mismatch

## Symptom

`RelayAuditMismatch` pages with a `kind` label. The `audit_verify` task (hourly full verification) or the `audit_readback` task (read-back of published checkpoints) found something that does not match:

| `kind` | Meaning |
|---|---|
| `published_mismatch` | The object a target holds differs from the recorded signed checkpoint |
| `published_missing` | A target that reported a checkpoint published no longer has it |
| `root_mismatch` | A root rebuilt from the audit records differs from the recorded root |
| `leaf_mismatch` | A leaf recomputed from its audit record differs from the stored leaf |
| `record_missing` / `index_gap` | A leaf points to a record that does not exist, or leaves are missing |
| `note_invalid` | A recorded checkpoint does not verify against the checkpoint key |
| `record_unintegrated` | Audit records below the watermark never got a leaf |
| `target_unlocked` | A publication target no longer has object lock on |

The node logs `audit verification mismatch` or `published audit checkpoint differs from the record`.

## Impact

Delivery is not affected. The audit trail of the installation may have been changed, lost or not committed to, so every tenant's "who did what" evidence is in question until the cause is known. Until then treat it as tampering. Nothing here can be undone: evidence must be kept as found.

## Diagnosis

The tasks that report mismatches and their state:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT name, leader_node, lease_until, updated_at, state FROM relay.singleton_tasks WHERE name IN ('audit_verify', 'audit_readback', 'audit_checkpoint')"
```

Recorded checkpoints of the affected log, newest first (the `origin` is in the node log line):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT id, log_origin, tree_size, encode(root_hash, 'hex') AS root, is_heartbeat, created_at FROM relay.audit_checkpoints ORDER BY created_at DESC LIMIT 20"
```

Where each checkpoint was published and what each target answered:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT p.checkpoint_id, p.target, p.status, p.detail, p.created_at FROM relay.audit_checkpoint_publications p ORDER BY p.created_at DESC LIMIT 40"
```

Compare the `signed_note` of the reported tree size with the object the target holds (download it with the target's own tools, for example the object store console or `aws s3 cp`); keep both copies.

## Decision tree

```text
RelayAuditMismatch
├── kind = target_unlocked
│   └── object lock was switched off on the store: security incident, restore lock, find who changed it
├── kind = published_missing or published_mismatch
│   ├── target content was changed or removed outside Relay
│   │   └── security incident on the target; preserve the store's access logs
│   └── target reachable but returns another object (wrong bucket, prefix or configuration)
│       └── fix the configuration; the next read-back reports again
├── kind = root_mismatch, leaf_mismatch, record_missing, index_gap
│   └── the database audit rows or leaves changed: security incident, freeze database access
├── kind = note_invalid
│   └── wrong checkpoint key or a forged note: security incident, check the key store
└── kind = record_unintegrated
    └── the checkpoint task skipped records: follow audit-checkpoint.md, then escalate
```

## Mitigation

Do not repair, delete or re-sign anything: the audit tables are append-only and the evidence is the point. Stop further damage instead:

1. Declare a SEV1 incident (see `incident/`) and name a security owner.
2. Take a snapshot of the database for evidence (in your database platform's console, or a `pg_dump` of the `relay` schema's `audit_log`, `audit_leaves`, `audit_checkpoints` and `audit_checkpoint_publications` tables):

```sh state-changing
pg_dump "$PG_ADMIN_URL" -Fc -t relay.audit_log -t relay.audit_leaves -t relay.audit_checkpoints -t relay.audit_checkpoint_publications -f relay-audit-evidence.dump
```

3. Restrict who can reach the database and the publication targets until the cause is known.

## Fix and escalation

Escalate at once to the installation's security owner and the Relay engineering on-call. The fix depends on the cause found; a configuration mistake is fixed in configuration, anything else follows the security incident process, including the customer notification decision made by the incident commander.
