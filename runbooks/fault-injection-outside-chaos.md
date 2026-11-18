---
id: fault-injection-outside-chaos
severity: SEV2
channels: [all]
tenant_scope: installation
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

None on delivery yet: a node that is not in chaos mode never acts on a fault injection for the `live` environment. The record should not exist at all, because the operator API and the release command refuse it outside chaos mode; it was written past them, for example by hand in the database. If the node is later started with `RELAY_CHAOS_MODE=true` while the record is still in force, live traffic would receive injected failures.

## Diagnosis

1. List the records in force and recently cleared:

   ```sh
   bin/relay eval 'Relay.Release.FaultInjection.list(include_inactive: true) |> IO.inspect()'
   ```

2. Read the `fault_injection.engaged` audit records of the installation scope for the record's identifier, its creator and its reason.
3. Check that no node runs with `RELAY_CHAOS_MODE=true` in this installation.

## Decision tree

- The record names a game day ticket and the region is a chaos region that lost its `RELAY_CHAOS_MODE` setting: clear the record, restore the setting only if the game day is still planned, and engage it again through the release command.
- The record has no known owner: clear it and treat the write as a security incident.
- The alert stays after the record is cleared: a node holds a stale cache; check its Valkey signal and wait at most 30 seconds for its re-read.

## Mitigation

Clear the record (the identifier is the `fij_` value of the listing):

```sh state-changing
bin/relay eval 'Relay.Release.FaultInjection.clear("fij_...", operator: "you@example.com", reason: "fault injection outside chaos mode") |> IO.inspect()'
```

Running the command twice is safe: the second run answers `already_cleared`.

## Fix and escalation

Find how the record was written. A direct database write bypassed the operator surface and its step-up; escalate to the security on-call with the audit records and the database connection logs of the time the record was created.
