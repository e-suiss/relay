---
id: agent-silent-waitpoints
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelayAgentSilentWaitpoints]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Silent waitpoints

## Symptom

`RelayAgentSilentWaitpoints` fires: for half an hour more than 50 waitpoints have been `open` or `stalled` without any state change for the silence period (a day by default; `x-relay-limits` `agent_operations.silent_after`). Silence is not an error, so no error counter shows it: the people or agents asked are not answering, or the waiters stopped sending heartbeats. The gauge `relay_agents_waitpoints_silent` is measured across tenants by the missed-timer sweep.

## Impact

Agents wait for answers that do not come. Their work is blocked until each waitpoint resolves or reaches its deadline. Nothing is lost in Relay; the cost is in the tenants' workflows and in decisions that may fall back to their defaults.

## Diagnosis

The gauges now (silent and stalled):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_agents_waitpoints_silent or relay_agents_waitpoints_stalled' | jq -r '.data.result[] | "\(.metric.__name__) \(.value[1])"'
```

The tenants that hold the silent waitpoints:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, environment, state, kind, count(*), min(state_changed_at) FROM relay.waitpoints WHERE state IN ('open', 'stalled') AND state_changed_at <= now() - interval '1 day' GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC LIMIT 20"
```

`stalled` means the waiter stopped sending heartbeats (`heartbeat_due_at` passed). `open` means the waiter is alive but nobody has answered.

The oldest silent waitpoints of one tenant, with their deadlines and escalation (replace the tenant):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT id, kind, state, opened_at, state_changed_at, expires_at, escalation_policy_ref, next_escalation_at FROM relay.waitpoints WHERE tenant_id = '00000000-0000-0000-0000-000000000000' AND state IN ('open', 'stalled') AND state_changed_at <= now() - interval '1 day' ORDER BY state_changed_at LIMIT 20"
```

A `next_escalation_at` in the past means the escalation timer did not fire. The tenant lists the same with `GET /v1/waitpoints?state=open` and `state=stalled`; per waitpoint, the console shows whether its notifications were delivered.

## Decision tree

```text
RelayAgentSilentWaitpoints
├── mostly stalled
│   └── waiters stopped heartbeating: tell the tenant its agents are down or stuck
├── mostly open, one tenant
│   ├── notifications delivered
│   │   └── responders do not answer: tell the tenant
│   └── notifications skipped or failed
│       └── delivery problem: follow that rule's or provider's runbook
├── next_escalation_at in the past on many rows
│   └── escalation timers not firing: escalate to the agents owners
└── spread across many tenants after a deploy
    └── treat as a regression: escalate, consider rollback
```

## Mitigation

Tell the tenant that owns the waiters. A waitpoint expires by itself at its deadline; Relay never answers, cancels or extends a waitpoint on the tenant's behalf.

## Fix and escalation

The tenant fixes its waiters (heartbeats, deadlines) or its responders and escalation policy. Escalation timers that do not fire go to the agents owners with waitpoint identifiers and times.
