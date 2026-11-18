---
id: queue-polling
kind: alert
severity: SEV3
channels: [all]
tenant_scope: all
alerts: [RelayQueuePolling]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 20
reversible: true
---

# Job queue polling

## Symptom

`RelayQueuePolling` (warning) fires with a `component` label (`notifier` or `stager`): for five minutes the job queue has not received notifications through Valkey and falls back to polling PostgreSQL. The node logs `queue notifier disconnected; the queue polls until Valkey returns` or `valkey pub/sub connection lost`.

## Impact

No job is lost: jobs live in PostgreSQL and are still picked up. Each job starts later (up to the polling interval) and the database gets more queries. If Valkey is down, rate limits, kill switch signals and realtime fan-out use their fallbacks too, so check `valkey-loss.md` when more alerts fire.

## Diagnosis

Which nodes poll and since when:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_queue_polling == 1'
```

All nodes polling means Valkey itself; one node means that node's connection.

Does Valkey answer:

```sh
valkey-cli -u "$VALKEY_URL" PING
```

`PONG` means it is up. A timeout or `connection refused` means Valkey is down or unreachable.

Valkey's own view of its clients and memory:

```sh
valkey-cli -u "$VALKEY_URL" INFO clients
```

```sh
valkey-cli -u "$VALKEY_URL" INFO memory
```

`used_memory` close to `maxmemory` with the `noeviction` policy refuses writes: publishing then fails too.

## Decision tree

```text
relay_queue_polling == 1
├── valkey-cli PING fails
│   └── Valkey down: follow valkey-loss.md
├── PING ok, every node polls
│   ├── used_memory at maxmemory
│   │   └── raise maxmemory or free memory (Valkey operator)
│   └── memory fine
│       └── network policy or credentials changed between nodes and Valkey; fix it
└── PING ok, one node polls
    └── restart that node (Mitigation)
```

## Mitigation

Restore Valkey (its own runbook or provider console). When only one node polls, restart it so it reconnects:

```sh state-changing
kubectl delete pod relay-7c9d8b6f5-abcde
```

The alert clears five minutes after the node reconnects; no replay is needed.

## Fix and escalation

Find why the connection dropped (Valkey restart, failover, network). If polling repeats, escalate to whoever runs Valkey. Raise to SEV2 when queue latency alerts (`RelayQueueOldestJob`) fire at the same time.
