---
id: kill-switch-slow
kind: alert
severity: SEV1
channels: [all]
tenant_scope: some
alerts: [RelayKillSwitchSlow]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 10
reversible: true
---

# Kill switch slow

## Symptom

A kill switch took longer than its effect target (90 seconds) from the engaging transaction to the last batch of queued deliveries paused (`relay_slo_kill_switch_total{good="false"}`). The `platform` label says whether it was a platform-wide switch. The per-switch measurement is kept in `relay.kill_switch_effects`.

## Impact

While the sweep runs, deliveries that were already queued can still go out; the gate at the start of each delivery job catches most of them, but a slow sweep means the stop is less certain than promised. If the switch was engaged to stop a mass mis-send, every extra second is more wrong messages: treat it as SEV1 and follow mass-mis-send.md alongside.

## Diagnosis

The latest effects and how long they took:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT k.id, k.scope_kind, k.channel, k.message_class, e.paused_count, e.effect_delay_ms, e.effective_at FROM relay.kill_switch_effects e JOIN relay.kill_switches k ON k.tenant_id = e.tenant_id AND k.environment = e.environment AND k.id = e.kill_switch_id ORDER BY e.effective_at DESC LIMIT 10"
```

Kill switches in force, read live from the database through a node:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Release.KillSwitch.list(), limit: :infinity)'
```

Sweep jobs still running or waiting in the maintenance queue (the admin connection is needed for the queue schema):

```sh
psql "$PG_ADMIN_URL" -c "SELECT id, state, attempt, scheduled_at, attempted_at, args->>'kill_switch_id' AS kill_switch FROM relay_queue.oban_jobs WHERE worker = 'Relay.Tenancy.KillSwitch.Sweep' AND state NOT IN ('completed', 'discarded', 'cancelled') ORDER BY id DESC LIMIT 20"
```

A sweep job that snoozes again and again had too many matches per batch; one stuck in `available` means the `maintenance` queue is not draining.

Maintenance queue backlog:

```sh
psql "$PG_ADMIN_URL" -c "SELECT state, count(*), min(scheduled_at) FROM relay_queue.oban_jobs WHERE queue = 'maintenance' AND state IN ('available', 'scheduled', 'retryable', 'executing') GROUP BY state"
```

## Decision tree

```text
kill switch effect took longer than 90 s
├── sweep job still not completed
│   ├── maintenance queue backlog large -> other maintenance work starves the sweep:
│   │   keep the switch, let the sweep finish, report the backlog
│   └── sweep keeps snoozing -> very large paused_count; the gate holds the rest; wait
├── sweep completed, effect_delay_ms large, paused_count small
│   └── nodes picked up the signal late: check Valkey (valkey-loss.md); nodes re-read every 30 s
└── the switch was for a mass mis-send
    └── mass-mis-send.md; confirm the scope is paused in the console
```

## Mitigation

Confirm the stop holds: the record must be listed as active above and the console must show the scope paused. If the console and API are unreachable, use kill-switch-emergency.md. To make the stop wider while the sweep catches up, engage a broader switch, for example the whole tenant on that channel:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"widen slow stop\", ttl: \"2h\", scope: :tenant, tenant: \"ten_REPLACE\", environment: :live, channel: \"email\"))"
```

## Fix and escalation

Find the slow batch from the sweep job's attempts and the maintenance queue load, and open an issue with the `kill_switch_effects` row. Kill switch propagation is a safety promise: escalate to the Relay engineering owner the same day.
