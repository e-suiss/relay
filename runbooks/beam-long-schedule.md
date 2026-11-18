---
id: beam-long-schedule
kind: alert
severity: SEV3
channels: [all]
tenant_scope: all
alerts: [RelayLongSchedule]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Long garbage collections or schedules

## Symptom

`RelayLongSchedule` (warning) fires with `kind` (`long_gc` or `long_schedule`) and `process` labels: in ten minutes the VM system monitor reported more than 20 times that one process ran for over 100 ms without yielding, or spent over 100 ms in one garbage collection. The `process` label is the process's registered name or initial call.

## Impact

While a process holds a scheduler for long stretches, every other process on that scheduler waits: request latency and job start times rise on the node, and the accept and handoff latency SLOs may follow. Nothing is lost. The effect is limited to the nodes where the process runs.

## Diagnosis

Which processes report, on which nodes, and how often:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (instance, kind, process) (increase(relay_vm_monitor_total{kind=~"long_gc|long_schedule"}[10m]))'
```

`long_gc` points at a process with a large heap; `long_schedule` at a process stuck in a long non-yielding call (a NIF, a large binary or term operation, a huge `Enum` over a list).

Heap size and reductions of processes with the label (replace the label with the alert's `process`):

```sh
$RELAY_EXEC bin/relay rpc 'Process.list() |> Enum.filter(&(Relay.Observability.VmMonitor.label(&1) == "Relay.Example.Worker")) |> Enum.map(&{&1, Process.info(&1, [:total_heap_size, :reductions, :message_queue_len, :current_function])}) |> IO.inspect(limit: 20)'
```

A `total_heap_size` in the millions of words explains long garbage collections; `current_function` shows where it runs now.

The largest heaps on the node regardless of label:

```sh
$RELAY_EXEC bin/relay rpc 'Process.list() |> Enum.map(&{Relay.Observability.VmMonitor.label(&1), Process.info(&1, :total_heap_size)}) |> Enum.sort_by(fn {_, {_, s}} -> s; _ -> 0 end, :desc) |> Enum.take(10) |> IO.inspect()'
```

## Decision tree

```text
long gc or schedule reports
├── kind = long_gc, the process holds a very large heap
│   └── it accumulates state or a big message: escalate for a fix; restart the node if latency SLOs burn
├── kind = long_schedule, current_function is a NIF or :crypto / :zlib call
│   └── large input on the send path; check dirty-scheduler-queue.md too
└── started with a deploy
    └── roll it back (Mitigation 2)
```

## Mitigation

If latency alerts fire on the node at the same time, restart it to drop the large heap (its work moves to other nodes):

```sh state-changing
kubectl delete pod relay-7c9d8b6f5-abcde
```

If the reports started with a deploy, roll back:

```sh state-changing
helm rollback relay
```

## Fix and escalation

Open an issue for the Relay engineering team with the label, the heap size and `current_function`. The fix splits the work into smaller steps, streams instead of building large terms, or moves heavy work off the scheduler.
