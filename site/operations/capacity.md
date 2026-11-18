# Capacity

::: warning Assumptions, not measurements
The figures on this page are engineering assumptions used to plan partitions, storage and queue sizes. They have not been measured on production hardware yet. Each one will be replaced by a measured value once it has been benchmarked, and you should measure your own installation before you rely on any of them.
:::

## Working assumptions

- **Throughput per node:** low thousands of jobs per second, bounded by PostgreSQL. In practice the providers and the database are the bottleneck, not the Relay nodes.
- **Ledger events per delivery:** about three. Partition ranges and storage budgets are sized from this.
- **Queue jobs per delivery:** about 1.2. The queue table size and the WAL budget are sized from this.
- **Rate limiting on PostgreSQL:** 2,000 to 5,000 operations per second for a single key. Valkey is the primary rate limiter, so this matters only on the fallback path, where coarser limiting is acceptable.
- **Target utilisation:** 70%. Plan so that steady load uses about 70% of what a component can do, leaving room for bursts and failover.
- **Ten million push notifications:** minutes, limited by the push providers' quotas. Relay does not promise that a large send is instant.

## When one database is not enough

Take these steps in order, and move to the next only when measurement shows the previous one is exhausted:

1. Fix indexes and bloat.
2. Tune the queue table: per-partition autovacuum settings and its maintenance.
3. Move read load to the reporting role and to a read replica.
4. Move large tenants to their own installation.

Moving the job queue to a separate database is deliberately not on the list. Today a record, its job and its outbox entry are written in one transaction; splitting the queue out would break that guarantee and require a real outbox between two databases. It would only be done on the strength of measurements.

## Scaling nodes

Add nodes when the age of the oldest waiting job grows, not when CPU is high. See [scaling on queue age](./self-host#scaling).
