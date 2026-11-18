---
id: valkey-eviction-policy
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelayValkeyEvictionPolicy]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 10
reversible: true
---

# Valkey eviction policy is not noeviction

## Symptom

`RelayValkeyEvictionPolicy` pages: a node connected to Valkey and found `maxmemory-policy` set to something other than `noeviction`. The node logs `valkey eviction policy must be noeviction` with the policy it found.

## Impact

Under memory pressure Valkey silently drops keys. Relay keeps no record of truth in Valkey, but rate limiter buckets, frequency counters, concurrency slots and dedup hints live there: an evicted key resets a limit, so providers can be overrun and frequency caps under-count, for every tenant at once. Nothing is lost from PostgreSQL.

## Diagnosis

The policy Valkey runs with:

```sh
valkey-cli -u "$VALKEY_URL" CONFIG GET maxmemory-policy
```

Anything but `noeviction` confirms the alert.

Whether keys were already evicted:

```sh
valkey-cli -u "$VALKEY_URL" INFO stats
```

`evicted_keys` above 0 means limits were already reset at least once.

How close Valkey is to its memory limit:

```sh
valkey-cli -u "$VALKEY_URL" INFO memory
```

The node's own last check:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Platform.Valkey.Guard.status())'
```

`:ok` or `{:mismatch, "allkeys-lru"}`.

## Decision tree

```text
eviction policy mismatch
├── CONFIG GET shows noeviction already
│   └── the guard saw an older setting: ask it to check again (Mitigation 2)
├── CONFIG SET allowed (self-run Valkey)
│   └── set noeviction (Mitigation 1), then make it permanent in the configuration
└── CONFIG SET refused (managed Valkey)
    └── change the parameter group in the provider console
```

## Mitigation

1. Set the policy on the running server:

```sh state-changing
valkey-cli -u "$VALKEY_URL" CONFIG SET maxmemory-policy noeviction
```

2. Ask every node's guard to check again (each node clears its own gauge; run once per node):

```sh state-changing
$RELAY_EXEC bin/relay rpc 'send(Relay.Platform.Valkey.Guard, :check)'
```

With `noeviction`, a full Valkey refuses writes instead of dropping keys; Relay then falls back (polling, database limiter) instead of running with wrong counters.

## Fix and escalation

Put `maxmemory-policy noeviction` into the Valkey configuration file or the provider's parameter group so a restart keeps it, and size `maxmemory` with room for peak load. If `evicted_keys` was above zero, check provider throttling alerts for the period. Escalate to whoever runs Valkey if the setting is managed outside your control.
