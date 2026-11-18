---
id: postgres-archiver
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelayPostgresArchiverFailing]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# WAL archiving failing

## Symptom

`RelayPostgresArchiverFailing` fires when the last WAL archive attempt has been failing for 10 minutes.

## Impact

Point-in-time recovery stops at the last archived segment, so the recovery point objective grows with every minute. Unarchived WAL stays on the primary and fills its volume.

## Diagnosis

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time FROM pg_stat_archiver"
kubectl logs "$PRIMARY_POD" -c postgres --since=30m | grep -i archive
```

## Decision tree

```text
1. The object store rejects the upload (credentials, bucket policy, object lock): fix the store side.
2. The object store is unreachable: check the network path inside the region.
3. The archive command itself fails: check the operator and plugin versions.
```

## Mitigation

Restore access to the in-region object store. Do not switch the archive to a store outside the region. Once uploads succeed, the archiver catches up on its own.

```sh state-changing
kubectl rollout restart deployment "$BARMAN_PLUGIN_DEPLOYMENT"
```

## Fix and escalation

Take a fresh base backup once archiving works again, so that recovery does not depend on the gap. Escalate to the database owner on call if archiving does not resume within 30 minutes.
