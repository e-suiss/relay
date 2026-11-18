---
id: beam-long-message-queue
kind: alert
severity: SEV3
channels: [all]
tenant_scope: all
alerts: [RelayLongMessageQueue]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Long message queue

## Symptom

`RelayLongMessageQueue` (warning) fires with a `process` label: in the last ten minutes the VM system monitor reported a process whose message queue passed 10 000 messages (it reports again after the queue fell below 5 000 and rose again).

## Impact

The process falls behind its senders. Whatever it serves (a cache, a dispatcher, a connection, a telemetry handler) answers late or times out, and its memory grows with the queue until the node runs out of memory. The effect is on the node that runs the process; a singleton process (dispatcher, controller) affects the whole installation.

## Diagnosis

Which processes report and on which nodes:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (instance, process) (increase(relay_vm_monitor_total{kind="long_message_queue"}[30m]))'
```

The longest queues on the node now, with what each process is doing:

```sh
$RELAY_EXEC bin/relay rpc 'Process.list() |> Enum.map(&{&1, Process.info(&1, [:message_queue_len, :current_function])}) |> Enum.filter(fn {_, i} -> i && i[:message_queue_len] > 1000 end) |> Enum.map(fn {p, i} -> {Relay.Observability.VmMonitor.label(p), i} end) |> IO.inspect(limit: 20)'
```

A queue that keeps growing between two runs means the process cannot keep up; a queue that shrinks means a burst it is working off.

Node memory, since the queue lives on the heap:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_vm_memory_total'
```

## Decision tree

```text
long message queue
├── queue shrinking between runs
│   └── burst being worked off: watch, no action
├── queue growing, process is a singleton task or dispatcher
│   └── upstream floods it: reduce the source (load shedding, kill switch on the flooding scope)
└── queue growing, memory climbing toward the container limit
    └── restart the node before it is killed for memory (Mitigation)
```

## Mitigation

Never kill the process to drop its messages: they may be signals, acknowledgements or work items. Apply backpressure upstream instead, for example by pausing the flooding campaign or workflow with a kill switch (`relay kill-switch engage --scope campaign …`, see `kill-switch-emergency.md` for other paths). If the node's memory is about to hit its limit, restart the whole node in an orderly way so jobs return to the queue:

```sh state-changing
kubectl delete pod relay-7c9d8b6f5-abcde
```

## Fix and escalation

Open an issue for the Relay engineering team with the label, queue length and `current_function`. The fix adds backpressure (bounded calls instead of casts, batching, a pool) where the messages come from.
