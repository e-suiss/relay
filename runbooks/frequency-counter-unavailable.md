---
id: frequency-counter-unavailable
kind: alert
severity: SEV3
channels: [all]
tenant_scope: all
alerts: [RelayFrequencyCounterUnavailable]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 20
reversible: true
---

# Frequency counter unavailable

## Symptom

`RelayFrequencyCounterUnavailable` (warning) fires: in the last five minutes reading or recording a frequency counter in Valkey failed. The node logs `frequency counter unavailable (read, <code>); frequency caps fail open` or the same with `record`.

## Impact

Frequency caps (per recipient, and per recipient, category and channel) fail open while Valkey does not answer: recipients may get more messages than their caps allow. Nothing is blocked and nothing is lost. A failed `record` means deliveries sent in that period are not counted, so caps under-count for the length of their window after Valkey returns. Every tenant that uses frequency caps is affected.

## Diagnosis

Failures by operation and node:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (instance, op) (increase(relay_frequency_counter_unavailable_total[5m]))'
```

Every node failing means Valkey; one node means its connection.

Valkey health and latency:

```sh
valkey-cli -u "$VALKEY_URL" PING
```

```sh
valkey-cli -u "$VALKEY_URL" --latency -i 1 -c 10
```

A `PING` that fails, or latency in hundreds of milliseconds, explains the timeouts.

Whether Valkey refuses writes because it is full:

```sh
valkey-cli -u "$VALKEY_URL" INFO memory
```

## Decision tree

```text
frequency counter unavailable
├── PING fails
│   └── Valkey down: follow valkey-loss.md
├── PING ok, latency high
│   └── Valkey overloaded: check its CPU and the largest key patterns with the Valkey operator
├── used_memory at maxmemory (noeviction)
│   └── writes refused: raise maxmemory (Valkey operator)
└── only one node fails
    └── restart that node (Mitigation)
```

## Mitigation

Restore Valkey. If one node alone fails, restart it:

```sh state-changing
kubectl delete pod relay-7c9d8b6f5-abcde
```

Caps resume on the next read once Valkey answers. If recipients complain about too many messages in a high-volume tenant during the outage, the tenant can pause the affected campaign or workflow with a kill switch (`relay kill-switch engage --scope campaign …`).

## Fix and escalation

Find why Valkey stopped answering (restart, failover, memory, network) and fix it with whoever runs Valkey. Raise to SEV2 if the outage lasts long enough that marketing volume to the same recipients clearly exceeds their caps.
