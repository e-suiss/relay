---
id: postgres-replication-slot
severity: SEV2
channels: [all]
tenant_scope: installation
alerts: [RelayPostgresSlotInactive, RelayPostgresSlotWalRetention, RelayPostgresSlotWalAtRisk]
last_tested: 2026-11-18
tested_by: none
automation: 0
eta_minutes: 30
reversible: false
---

# Replication slot without a consumer or keeping too much WAL

## Symptom

`RelayPostgresSlotInactive` fires when a slot has had no consumer for 30 minutes, `RelayPostgresSlotWalRetention` when a slot keeps more than 75% of `max_slot_wal_keep_size` (64 GB), and `RelayPostgresSlotWalAtRisk` when its `wal_status` is `unreserved` or `lost`.

## Impact

An abandoned slot pins WAL on the primary until the disk fills. A slot whose WAL is lost can no longer serve its standby or consumer, which must be rebuilt.

## Diagnosis

```sh
psql "$ADMIN_DATABASE_URL" -c "SELECT slot_name, slot_type, active, inactive_since, wal_status, pg_size_pretty(safe_wal_size) AS safe, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS kept FROM pg_replication_slots"
```

Find the owner of the slot: a standby of the HA cluster, a connector or an external consumer.

## Decision tree

1. The slot belongs to a standby that is restarting or catching up: watch it; it clears on its own.
2. The consumer is gone for good: drop the slot.
3. The WAL is lost: drop the slot and rebuild the standby or consumer from a fresh base backup.

## Mitigation

Drop an abandoned slot; never delete files under `pg_wal` by hand.

```sh state-changing
psql "$ADMIN_DATABASE_URL" -c "SELECT pg_drop_replication_slot('$SLOT')"
```

## Fix and escalation

Remove the stale consumer from its configuration so that the slot is not created again. Escalate to the database owner on call when a standby of the HA cluster has lost its WAL.
