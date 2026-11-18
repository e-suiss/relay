---
id: beam-atoms
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelayAtomGrowth, RelayAtomLimit]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Atom table growth or near its limit

## Symptom

- `RelayAtomGrowth` (warning): a node's atom table grew by more than 1000 atoms an hour for an hour (`relay_vm_atom_count`).
- `RelayAtomLimit` (page): a node's atom table is more than 80% full (`relay_vm_atom_count / relay_vm_atom_limit`).

## Impact

Atoms are never freed. A full atom table crashes the whole node at once, with every request and job on it. Steady growth means some code turns data (tenant input, provider codes, header names) into atoms; every node running that code drifts toward the same crash, so the whole installation is at risk, in hours or days depending on the rate.

## Diagnosis

Atom count, limit and growth per node:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_vm_atom_count / relay_vm_atom_limit'
```

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=deriv(relay_vm_atom_count[1h]) * 3600'
```

Nodes that grow and nodes that do not tell which role or workload creates atoms (compare with `RELAY_ROLES` of each).

The newest atoms on one node, which usually show their source by their shape (a provider code, a JSON key, a tenant value):

```sh
$RELAY_EXEC bin/relay rpc 'n = :erlang.system_info(:atom_count); IO.inspect(for i <- max(n - 50, 0)..(n - 1), do: :erlang.binary_to_term(<<131, 75, i::24>>), limit: :infinity)'
```

If that external-term trick fails on the running OTP version, compare `:erlang.system_info(:atom_count)` before and after a suspected request instead:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(:erlang.system_info(:atom_count))'
```

## Decision tree

```text
atom alarm
├── only RelayAtomGrowth, ratio below 50%
│   └── find the source (Diagnosis), fix in working hours
├── RelayAtomLimit, one node far ahead of the others
│   └── restart that node in a quiet moment (Mitigation)
└── RelayAtomLimit on every node of a role
    ├── a recent deploy started the growth
    │   └── roll it back (Mitigation 2), then restart nodes one by one
    └── no deploy: tenant input drives it
        └── restart nodes one by one, escalate for a code fix
```

## Mitigation

A restart is the only way to empty the atom table. Restart the node that is closest to the limit, one at a time so the others keep serving:

```sh state-changing
kubectl delete pod relay-7c9d8b6f5-abcde
```

When the growth began with a deploy, roll it back first so restarted nodes do not fill up again (Helm example):

```sh state-changing
helm rollback relay
```

## Fix and escalation

Escalate to the Relay engineering on-call with the newest atoms. The fix is a code change: data must never become atoms (`String.to_existing_atom/1` or a fixed mapping instead of `String.to_atom/1`). The CI lint for unsafe conversions should have caught it; add the missed pattern there.
