---
id: integrity-stale
kind: alert
severity: SEV3
channels: [none]
tenant_scope: all
alerts: [RelayIntegrityStale, RelayIntegrityUnreported]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Integrity check stale or unreported

## Symptom

- `RelayIntegrityStale`: the newest completed nightly integrity check reported by any node is older than 36 hours.
- `RelayIntegrityUnreported`: for 36 hours no node has exported `relay_integrity_last_run_timestamp_seconds` at all, so Prometheus has never seen a completed run since the nodes started.

Both page because a silent integrity check hides the problems it exists to find.

## Impact

Nothing is broken by the missing run itself. Orphan rows, broken references and a short partition horizon go unnoticed until the check runs again. All tenants of the installation are covered by the same check.

## Diagnosis

When the task last saved a report, and who leads it:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT leader_node, lease_until, updated_at, state->>'checked_at' AS checked_at FROM relay.singleton_tasks WHERE name = 'integrity_check'"
```

A recent `checked_at` with the alert still firing means the run completed but the metric did not reach Prometheus (the leader restarted after the run, or Prometheus does not scrape the worker nodes). An old `checked_at` means the task did not run.

Which nodes Prometheus scrapes:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=up{job=~".*relay.*"}'
```

Whether any node runs the worker role:

```sh
$RELAY_EXEC printenv RELAY_ROLES
```

## Decision tree

```text
integrity check stale or unreported
├── lease expired or no worker node
│   └── follow singleton-leaderless.md
├── checked_at recent (< 36 h)
│   ├── worker nodes not scraped
│   │   └── fix the Prometheus scrape configuration
│   └── leader restarted after the run (metric lost with the node)
│       └── run the check now (Mitigation) or wait for the next nightly run
└── checked_at old, lease held
    └── the step fails: read "singleton task step failed" in the leader's log, then run the check (Mitigation)
```

## Mitigation

Run the check once now on a node; it is read-only, reports through the same telemetry and prints the violations:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Platform.Maintenance.IntegrityTask.check())'
```

`{:ok, %{"violations" => []}}` means clean. Any violation raises `RelayIntegrityViolation`: follow `integrity-violation.md`. The manual run does not refresh the nightly timestamp; the alert clears after the next nightly run completes, which a restart of the leader makes happen at once:

```sh state-changing
kubectl delete pod relay-7c9d8b6f5-abcde
```

## Fix and escalation

Make sure at least one node runs with `worker` in `RELAY_ROLES` and is scraped by Prometheus. If the step keeps failing with the same error code, escalate to the Relay engineering on-call.
