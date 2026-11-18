---
id: postgres-failover
kind: procedure
severity: SEV1
channels: [all]
tenant_scope: all
alerts: []
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 15
reversible: false
---

# PostgreSQL failover

## Symptom

The primary PostgreSQL is gone or must be replaced: nodes answer `503` on `/readyz` with `database unavailable`, the API answers `503` to every write, and jobs stop. Or a planned switchover to a replica is due.

## Impact

PostgreSQL is the truth for every accepted message, every job and every kill switch. While it is down nothing is accepted (clients get `503` and retry with their idempotency keys) and nothing is sent. Nothing accepted is lost as long as the new primary holds every committed transaction: promote only a replica that was synchronous, or accept and record the loss window.

## Diagnosis

What the nodes see:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' "$RELAY_URL/readyz"
```

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Platform.health())'
```

`database: {:error, …}` with `key_store: :ok` and `valkey: :ok` confirms the database is the problem.

On the replica you mean to promote: is it a replica, and how far behind was it?

```sh
psql "$PG_ADMIN_URL" -Atc "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), now() - pg_last_xact_replay_timestamp() AS replay_lag"
```

When the old primary is still reachable, compare its last LSN with the replica's (`SELECT pg_current_wal_lsn()` there); equal means nothing committed is missing.

After the switch, the nodes must reach the new primary through the same `DATABASE_URL`, `MAINT_DATABASE_URL`, `REPORT_DATABASE_URL` and `QUEUE_DATABASE_URL` host (a service name or a virtual IP that moved), or be redeployed with the new host.

## Decision tree

```text
database unavailable
├── managed service (failover is the provider's)
│   └── wait for its failover, then check readiness and the checks below
├── primary down, synchronous replica healthy
│   └── promote it (Mitigation 1), move the endpoint, check
├── primary down, only asynchronous replicas
│   ├── primary can come back within the RTO -> bring it back instead
│   └── it cannot -> incident commander decides: promote and record the
│       loss window (accepted-but-lost = SEV1, tenants told per class)
└── planned switchover
    └── stop writes first: scale nodes to zero (Mitigation 2), switch, scale back
```

## Mitigation

1. Promote the replica (self-managed PostgreSQL; with an operator such as Patroni or CloudNativePG use its own switchover command instead):

```sh state-changing
psql "$PG_ADMIN_URL" -c "SELECT pg_promote(wait => true)"
```

2. For a planned switchover, stop the nodes before it so that no write is in flight:

```sh state-changing
kubectl scale deploy/relay-all --replicas=0
```

3. Restart the nodes so that every pool reconnects to the new primary:

```sh state-changing
kubectl rollout restart deploy/relay-all
```

Then check, in order: `/readyz` answers `200`; `Relay.Release.KillSwitch.list()` returns the kill switches you expect; the partition horizon is fine (`partition-horizon.md`); the funnel shows no accepted-but-not-queued deliveries (`funnel-data-loss.md`).

## Fix and escalation

Rebuild a replica for the new primary at once: until it exists the installation runs without a failover target. Measure and record the time from loss to `/readyz` green and the data loss window; these are the recovery numbers the game day verifies. Escalate to the database owner on call for any promotion that is not synchronous.
