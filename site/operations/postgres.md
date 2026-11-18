# PostgreSQL HA and recovery

PostgreSQL holds everything Relay must not lose: accepted events, the delivery ledger, the job queue and the audit trail. Valkey holds only signals, counters and caches. This page covers how to keep PostgreSQL available, how to recover it, and how to size connections.

## High availability

Use your cloud's managed high availability when you have one. On Kubernetes, use a mature PostgreSQL operator; the example below uses [CloudNativePG](https://cloudnative-pg.io/).

Whatever you choose, replicate synchronously to a quorum: a commit waits until any one of the standbys has it. Do not name one fixed synchronous standby. If that single standby fails, every commit on the primary waits for it, and a standby failure turns into an outage.

### CloudNativePG

Run three instances, a quorum of one, and a WAL archive that is flushed at least once a minute. These fields go in the specification block of the `Cluster` resource:

```yaml
instances: 3
postgresql:
  synchronous:
    method: any
    number: 1
  parameters:
    archive_timeout: "60s"
```

Send WAL archives and base backups to an object store in the same region as the cluster, using the backup method your CloudNativePG version recommends (the Barman Cloud plugin in current versions). Never point the archive at a bucket in another region.

### Managed high availability

A managed service is equivalent when it gives you the same three properties: synchronous replication to at least one standby in another zone of the same region, automatic failover, and point-in-time recovery from backups kept in the same region.

### Local development

The compose stack runs one PostgreSQL with no replicas. The nightly tests rehearse failover there by restarting PostgreSQL; the region acceptance test rehearses a real failover.

## Recovery targets

| Situation                                   | Data loss target (RPO) | Recovery time target (RTO) |
| ------------------------------------------- | ---------------------- | -------------------------- |
| Failover to a standby in the region         | none                   | 2 minutes or less          |
| Point-in-time recovery from the WAL archive | 5 minutes or less      | 4 hours or less            |

These are targets, not measured results. They are first measured in the failover and restore drills of the [region acceptance test](./regions#accepting-a-region). A region whose measurement misses a target does not advertise that target, and the miss is handled as an incident.

## A failover can duplicate, never lose

After a failover some jobs run a second time: a job that had already called a provider may be picked up again by another node. Relay absorbs this with durable idempotency. Every delivery has a unique ledger entry, and a repeated job finds the existing entry instead of creating a second one. Your clients should do the same: a request can time out even though its transaction committed, so always send an `Idempotency-Key` and retry with the same key. See [Guarantees and idempotency](/guide/guarantees).

When a connection lands on a database that has become read-only, Relay closes that connection and opens a new one, so it reaches the new primary instead of failing repeatedly.

## Losing Valkey loses no data

If Valkey restarts or disappears, signals fall back to polling, counters fall back to PostgreSQL, and realtime clients recover from their cursors. Valkey needs no backup; high availability for it is optional.

## Connection pooling

Each Relay node opens a fixed pool of connections (`POOL_SIZE`, Helm value `poolSize`). During a rolling deployment old and new nodes run side by side, so count every pool twice:

- if nodes × pool size × 2 stays below about half of PostgreSQL's `max_connections`, connect directly and do not add a pooler;
- if it does not, or if nodes scale automatically, put PgBouncer in transaction mode between Relay and PostgreSQL. The Helm chart can deploy one for you. Use a current PgBouncer release, but not a minor version on its first day.

Relay checks this rule at boot and logs a warning and exposes a metric when the rule is broken and no pooler is configured. Relay does not use `LISTEN/NOTIFY`, so transaction-mode pooling places no limits on it.

When every connection is busy and a request has waited its turn, the API answers `503` with `Retry-After`. That is load shedding by design. It tells clients to come back later; it is not a sign that the pool should be made larger.
