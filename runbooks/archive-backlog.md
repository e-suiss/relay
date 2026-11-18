---
id: archive-backlog
severity: SEV4
channels: [ticket]
tenant_scope: installation
alerts: [RelayArchiveBacklog]
last_tested: 2026-11-18
tested_by: none
automation: 2
eta_minutes: 60
reversible: true
---

# Cold archive backlog

## Symptom

`RelayArchiveBacklog` fires: a detached partition has waited more than two days for the cold archive.

## Impact

None for tenants. Detached partitions use disk space in the database until they are archived.

## Diagnosis

Read `relay_archive_backlog`, `relay_archive_backlog_age_seconds` and `relay_leadership_leaderless{task="partition_archive"}`. List the waiting partitions with `SELECT * FROM relay_private.archive_leaves()` as `relay_archive`.

## Decision tree

- The task has no leader: no worker node runs, or none has `ARCHIVE_DATABASE_URL` and the archive bucket configured.
- Attempts fail: follow `runbooks/archive-failing.md`.
- Attempts succeed but the backlog grows: more partitions are detached per day than one archive step can move; check the partition sizes.

## Mitigation

Start or fix a worker node with the archive settings and let the task take its lease.

## Fix and escalation

If the backlog keeps growing with a healthy task, escalate to the platform owner with the partition sizes.
