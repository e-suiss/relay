---
id: archive-failure
kind: alert
severity: SEV3
channels: [all]
tenant_scope: all
alerts: [RelayArchiveFailing, RelayArchiveBacklog]
last_tested: 2026-11-18
tested_by: none
automation: 2
eta_minutes: 60
reversible: true
---

# Archive failure

## Symptom

`RelayArchiveFailing` fires when the `partition_archive` task failed three or more attempts in a row to move a detached partition to the cold archive. `RelayArchiveBacklog` fires when a detached partition has waited more than two days for the cold archive, even if no attempt failed (the task has no leader, or no worker node has the archive settings).

## Impact

No message is lost and nothing stops at first. A failed attempt never removes the hot copy: the partition stays detached in the database, its manifest records the failure and the next step starts from scratch. A growing backlog means a growing disk, slower vacuums and longer backups; on a full disk PostgreSQL stops accepting writes, which is SEV1. Detached tables keep their ciphertext in the hot database until they are archived, so retention promises slip while the backlog exists.

## Diagnosis

Detached partitions waiting for the archive, oldest first (as `relay_archive`):

```sh
psql "$ARCHIVE_DATABASE_URL" -c "SELECT table_name, leaf_name, range_from, retain_days FROM relay_private.archive_leaves()"
```

The newest archive attempts and their failure codes:

```sh
psql "$ARCHIVE_DATABASE_URL" -c "SELECT leaf_name, status, failure_code, started_at FROM relay.archive_manifests ORDER BY started_at DESC LIMIT 20"
```

Metrics: `relay_archive_failures` (attempts in a row that failed), `relay_archive_failure_timestamp_seconds` by `code`, `relay_archive_backlog` and `relay_archive_backlog_age_seconds`, and `relay_leadership_leaderless{task="partition_archive"}`.

Partitions past their hot retention that are not detached yet:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT table_name, partition_name, upper_bound FROM relay_ops.partition_due_for_archive() ORDER BY upper_bound LIMIT 20"
```

## Decision tree

```text
archive alarm
├── partition_archive has no leader -> singleton-leaderless.md
│   └── no worker node has ARCHIVE_DATABASE_URL and ARCHIVE_S3_* -> configure one
├── failure_code archive_unconfigured or target_unlocked
│   └── archive bucket missing, or without object lock and a default retention rule
├── failure_code publication_unreachable or publication_refused
│   └── object store down or credentials expired -> fix the target
├── failure_code retention_unknown -> no active retention_periods data set
├── failure_code parquet_* -> archive_port missing, failing its checksum or its scratch disk
├── failure_code archive_mismatch -> the object read back differs; treat the store as suspect, escalate
├── archive_refused with count_mismatch -> the partition changed after verification, escalate
└── disk above 80% -> raise the volume first (Mitigation), then work the backlog
```

## Mitigation

The first goal is disk headroom; the backlog is worked off afterwards, one partition per archive step. Grow the database volume (Kubernetes example; managed databases have their own storage setting):

```sh state-changing
kubectl patch pvc data-postgres-0 -p '{"spec":{"resources":{"requests":{"storage":"500Gi"}}}}'
```

Never drop a detached table by hand: only `relay_archive` removes the hot copy, through `relay_private.archive_drop`, after the archived copy was read back from the store and matched its row count and digest.

## Fix and escalation

Fix the cause the decision tree found; the task retries from scratch on its next step and `relay_archive_failures` returns to 0. An archived partition can be checked by restoring it into a read-only schema with `bin/archive restore --manifest <manifest id> --schema restore_<name>`. Escalate to the database owner when the disk passes 85 %, and to the security and compliance lead on `archive_mismatch`, `count_mismatch` or retention dates missed by more than a week.
