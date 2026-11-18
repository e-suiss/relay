---
id: fault-injection-outside-chaos
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelayFaultInjectionOutsideChaos]
last_tested: 2026-11-18
tested_by: none
automation: 2
eta_minutes: 15
reversible: true
---

# Fault injection for live outside chaos mode

## Symptom

`RelayFaultInjectionOutsideChaos` pages: `relay_fault_injection_active{target_environment="live",chaos_mode="false"}` is above zero on at least one node.

## Impact

None on delivery yet: a node that does not run with `RELAY_CHAOS_MODE=true` never acts on a fault injection for the `live` environment. The record should not exist at all, because the operator API and the release command refuse it outside chaos mode; it was written past them, for example by hand in the database. If a node is later started with `RELAY_CHAOS_MODE=true` while the record is still in force (at most one hour after it was written), live traffic receives injected failures.

## Diagnosis

The records in force and the recently cleared ones, with their creator and reason:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Release.FaultInjection.list(include_inactive: true))'
```

A record with `environment: :live` and `status: :active` whose `expires_at` is still ahead is the one the alert sees. Its `created_by` and `reason` come from the `fault_injection.engaged` audit record of the installation scope.

Which nodes run in chaos mode (each line is one node; `chaos_mode="true"` means chaos mode):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_fault_injection_active{target_environment="live"}'
```

## Decision tree

```text
live fault injection in force, node not in chaos mode
├── record names a planned game day and this is a chaos region whose
│   RELAY_CHAOS_MODE setting was lost
│   └── clear it; restore the setting only if the game day still runs;
│       engage it again through the release command
├── record has no known owner
│   └── clear it; treat the write as a security incident
└── alert stays after the record is cleared
    └── a node holds a stale cache: it re-reads within 30 seconds;
        check its Valkey signal (valkey-loss.md)
```

## Mitigation

Clear the record (the `fij_` identifier from the listing):

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.FaultInjection.clear(\"fij_REPLACE\", operator: \"$RELAY_OPERATOR\", reason: \"fault injection outside chaos mode\"))"
```

Running it twice is safe: the second run answers `already_cleared`.

## Fix and escalation

Find how the record was written. A direct database write bypassed the operator surface; escalate to the security on-call (`incident/roles.md`) with the audit records and the database connection logs of the minute the record was created.
