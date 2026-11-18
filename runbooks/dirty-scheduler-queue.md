---
id: dirty-scheduler-queue
kind: alert
severity: SEV3
channels: [all]
tenant_scope: all
alerts: [RelayDirtySchedulerQueue]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Dirty CPU scheduler queue

## Symptom

`RelayDirtySchedulerQueue` (warning) fires: for five minutes the dirty CPU scheduler run queue of a node never fell to 10 or below (`relay_vm_dirty_cpu_run_queue`). Work that runs on dirty CPU schedulers (NIF calls marked dirty, `:crypto` on large inputs, garbage collection of very large heaps) waits in line.

## Impact

Calls that need a dirty scheduler slow down on that node: hashing, signing and encryption of large payloads, compression, and big garbage collections. Requests and sends that use them get slower, and the accept and handoff latency SLOs may follow. Nothing is lost.

## Diagnosis

Dirty CPU and dirty IO queues per node:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_vm_dirty_cpu_run_queue'
```

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_vm_dirty_io_run_queue'
```

Live run queues on the node (the last two numbers are dirty CPU and dirty IO) and the number of dirty CPU schedulers:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect({:erlang.statistics(:run_queue_lengths_all), :erlang.system_info(:dirty_cpu_schedulers_online)})'
```

Long garbage collections often run dirty, so check whether the same node reports them:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (instance, process) (increase(relay_vm_monitor_total{kind="long_gc"}[10m]))'
```

## Decision tree

```text
dirty CPU queue above 10
├── long_gc reports on the same node
│   └── large heaps: follow beam-long-schedule.md
├── traffic with large payloads (big email bodies, large batches) at the same time
│   └── expected under that load; scale out if latency SLOs burn
└── started with a deploy
    └── new dirty work on the send path: roll back (Mitigation 2)
```

## Mitigation

When latency SLOs burn, add nodes so the dirty work spreads (Kubernetes example):

```sh state-changing
kubectl scale deploy/relay-all --replicas=4
```

When the queue started with a deploy, roll it back:

```sh state-changing
helm rollback relay
```

## Fix and escalation

Open an issue for the Relay engineering team with the queue lengths and the workload of the time. The fix keeps dirty work off the send path (smaller inputs, work moved to a separate job) rather than raising the number of dirty schedulers without a measurement.
