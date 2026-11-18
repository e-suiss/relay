---
id: container-memory
severity: SEV2
channels: [all]
tenant_scope: installation
alerts: [RelayContainerMemoryHigh, RelayContainerMemoryCritical]
last_tested: 2026-11-18
tested_by: none
automation: 0
eta_minutes: 30
reversible: true
---

# Relay container close to its memory limit

## Symptom

`RelayContainerMemoryHigh` fires when a Relay container uses more than 75% of its memory limit for 15 minutes, `RelayContainerMemoryCritical` above 90%.

## Impact

The VM is meant to stay near 75% of the limit. Above 90% the kernel can kill the container at the next peak; its jobs return to the queue after their lease and its realtime connections reconnect elsewhere.

## Diagnosis

```sh
kubectl top pod -l app.kubernetes.io/name=relay --containers
kubectl exec "$POD" -c relay -- /app/bin/relay rpc ':erlang.memory() |> IO.inspect()'
```

Check `relay_vm_*` metrics and `RelayLongMessageQueue` for a growing process mailbox, and the binary and ETS shares of VM memory.

## Decision tree

1. One process mailbox grows: follow its own alert; apply backpressure, do not kill it.
2. Binary memory grows: look for long-lived references to large binaries.
3. Memory follows load and the peak was measured above the limit: raise the limit after measuring; raising it is not a fix for a leak.

## Mitigation

Take the node out of rotation with a rolling restart so that the drain order holds:

```sh state-changing
kubectl rollout restart deployment "$DEPLOYMENT"
```

## Fix and escalation

Fix the leak or set the limit above the measured peak. Escalate to the Relay owner on call if a node is killed for memory.
