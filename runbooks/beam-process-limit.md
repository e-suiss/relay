---
id: beam-process-limit
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelayProcessLimit]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Process table near its limit

## Symptom

`RelayProcessLimit` pages: a node's process table is more than 80% full (`relay_vm_process_count / relay_vm_process_limit`).

## Impact

When the table is full the node cannot start new processes: new requests, socket connections and jobs on that node fail while existing ones go on. Usually a supervisor keeps starting children that never end (a leak), or a burst of realtime connections lands on one node. Other nodes keep serving unless they share the cause.

## Diagnosis

Process use per node:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_vm_process_count / relay_vm_process_limit'
```

Which initial calls own the most processes on the alerting node (labels as the VM monitor reports them):

```sh
$RELAY_EXEC bin/relay rpc 'Process.list() |> Enum.frequencies_by(&Relay.Observability.VmMonitor.label/1) |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.take(15) |> IO.inspect()'
```

One label with tens of thousands of processes is the leak. Socket or channel processes leading means connection load: compare with the node's open connections.

Which supervisors have the most children:

```sh
$RELAY_EXEC bin/relay rpc 'Process.list() |> Enum.map(&{&1, Process.info(&1, :dictionary)}) |> Enum.flat_map(fn {_, {:dictionary, d}} -> List.wrap(d[:"$ancestors"]) |> Enum.take(1); _ -> [] end) |> Enum.frequencies() |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.take(10) |> IO.inspect()'
```

## Decision tree

```text
process table above 80%
├── one label dominates and keeps growing
│   └── leak: restart the node before it fills (Mitigation), escalate for the fix
├── realtime socket processes dominate
│   └── connection skew: check the load balancer spreads connections; scale socket nodes
└── many different labels, load high everywhere
    └── genuine load: scale out the node group (capacity-incident.md)
```

## Mitigation

Restart the node before the table fills; its work moves to the others and jobs are picked up again from the database:

```sh state-changing
kubectl delete pod relay-7c9d8b6f5-abcde
```

For genuine load, add nodes to the group (Kubernetes example):

```sh state-changing
kubectl scale deploy/relay-all --replicas=4
```

## Fix and escalation

Escalate a leak to the Relay engineering on-call with the top labels. The fix gives the leaking processes an end (idle timeout, bounded registry). Do not raise the process limit to hide a leak.
