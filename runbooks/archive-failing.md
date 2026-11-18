---
id: archive-failing
severity: SEV4
channels: [ticket]
tenant_scope: installation
alerts: [RelayArchiveFailing]
last_tested: 2026-11-18
tested_by: none
automation: 2
eta_minutes: 60
reversible: true
---

# Cold archive failing

## Symptom

`RelayArchiveFailing` fires: the `partition_archive` task failed three or more attempts in a row to move a detached partition to the cold archive.

## Impact

None for tenants. Detached partitions stay in the database and keep their disk space until an attempt succeeds; no data is lost, because a failed attempt never removes the hot copy.

## Diagnosis

Read `relay_archive_failure_timestamp_seconds` by `code` and the newest failed rows of `relay.archive_manifests` with their `failure_code`.

## Decision tree

- `archive_unconfigured` or `target_unlocked`: the archive bucket settings (`ARCHIVE_S3_*`) are missing, or the bucket has no object lock with a default retention rule.
- `publication_unreachable` or `publication_refused`: the object store is down or refuses the credentials.
- `retention_unknown`: no `retention_periods` data set is active.
- `parquet_*`: the `archive_port` program is missing, fails its checksum or cannot write the scratch directory.
- `archive_mismatch`: the object read back differs from what was written; treat the store as suspect.
- `archive_refused` with `count_mismatch`: the partition changed after its archive was verified; escalate.

## Mitigation

Fix the cause named by the code; the next step retries from scratch by itself. Never drop a detached partition by hand: only `relay_archive` removes the hot copy, after the read-back verification.

## Fix and escalation

If attempts keep failing after the cause is fixed, or the code is `archive_mismatch` or `count_mismatch`, escalate to the platform owner with the manifest ids.
