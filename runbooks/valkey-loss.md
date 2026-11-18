---
id: valkey-loss
kind: procedure
severity: SEV2
channels: [all]
tenant_scope: all
alerts: []
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 20
reversible: true
---

# Valkey loss

## Symptom

Valkey is down, restarted empty or unreachable: `/readyz` answers `503` with `Valkey unavailable`, `RelayQueuePolling` and `RelayFrequencyCounterUnavailable` fire, realtime connections drop and reconnect.

## Impact

Valkey holds no truth; PostgreSQL does. Nothing accepted is lost. What changes while it is gone:

- Job queue and kill switch signals fall back to polling: jobs and kill switch changes still reach every node, a little later (kill switch state is re-read every second while signals are down).
- Rate limits move to the PostgreSQL fallback limiter: correct, slower, more database load.
- Frequency caps fail open (a recipient may get more than the cap) and the agent ceiling fails closed (agent notifications are held).
- Nodes report not ready, so a load balancer that follows `/readyz` stops sending API traffic to them.

## Diagnosis

What each node sees:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Platform.health())'
```

`valkey: {:error, …}` with `database: :ok` confirms it. Is Valkey itself up, and did it lose its data?

```sh
valkey-cli -u "$VALKEY_URL" INFO server
```

```sh
valkey-cli -u "$VALKEY_URL" CONFIG GET maxmemory-policy
```

`uptime_in_seconds` small means it restarted; anything but `noeviction` is a separate fault (`valkey-eviction-policy.md`).

Which fallbacks are active:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (component) (relay_queue_polling)'
```

## Decision tree

```text
Valkey unavailable
├── Valkey process down or restarting
│   └── restart it (Mitigation 1); nodes return to ready on their own
├── Valkey up but unreachable from nodes (network, TLS, credentials)
│   └── fix the path; check VALKEY_URL of the nodes
├── Valkey up, reachable, eviction policy wrong
│   └── valkey-eviction-policy.md
└── outage longer than 15 minutes
    ├── database load rising from the fallback limiter
    │   └── capacity-incident.md (database branch: hold marketing)
    └── API traffic refused because nodes are not ready
        └── declare SEV2; customers see 503s with Retry-After
```

## Mitigation

1. Restart Valkey (Kubernetes example; use the name of your Valkey workload):

```sh state-changing
kubectl rollout restart statefulset/valkey
```

2. When the outage lasts and the database suffers from the fallback limiter, hold `marketing` (see `capacity-incident.md`):

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"valkey loss: database load\", ttl: \"1h\", scope: :platform, message_class: :marketing))"
```

After Valkey returns, check `relay_queue_polling` goes back to `0` for every component and `/readyz` answers `200` on every node.

## Fix and escalation

Find why Valkey went away (memory limit, node eviction, network policy). An empty Valkey after a restart needs no restore: every value in it is rebuilt from PostgreSQL or expires. Escalate to the platform team that runs Valkey if it does not come back within 15 minutes.
