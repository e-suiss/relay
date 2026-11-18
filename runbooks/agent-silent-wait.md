---
id: agent-silent-wait
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelayAgentSilentWait]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Agent silent wait

## Symptom

`RelayAgentSilentWait` fires: in the last hour at least one agent wait ended without any answer (`relay_agents_silent_wait_total`). An agent asked a person or another agent something through a waitpoint and the waitpoint expired with no response.

## Impact

The agent that waited goes on without the answer it asked for: it takes its default, gives up, or escalates, depending on how its owner built it. No message is lost in Relay, but a decision a human should have taken may have been taken by default. One expired wait is normal; many in one tenant mean its questions are not reaching anyone.

## Diagnosis

Waitpoints that expired in the last hour without a response, by tenant and kind:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, environment, kind, count(*) FROM relay.waitpoints WHERE state = 'expired' AND resolution_response_id IS NULL AND expired_at > now() - interval '1 hour' GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 20"
```

Whether their escalation steps ran (replace the tenant). Steps left `pending` or `armed` with a `due_at` in the past mean the escalation timer did not fire; `fired` steps mean the escalation reached its next responders:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT s.state, count(*), min(s.due_at) FROM relay.waitpoints w JOIN relay.waitpoint_steps s ON s.tenant_id = w.tenant_id AND s.environment = w.environment AND s.waitpoint_id = w.id WHERE w.tenant_id = '00000000-0000-0000-0000-000000000000' AND w.state = 'expired' AND w.expired_at > now() - interval '1 hour' GROUP BY 1"
```

Whether the questions reached anyone at all is visible per waitpoint in the console's waitpoint view and, for the tenant, in `GET /v1/notifications/{notification_id}/deliveries`: a skipped or failed delivery never reached the person.

Stalled waitpoints (a waiter that stopped sending heartbeats) across the installation:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_agents_waitpoints_stalled' | jq -r '.data.result[] | .value[1]'
```

## Decision tree

```text
RelayAgentSilentWait
├── deliveries of the questions were skipped or failed
│   └── delivery problem: follow the runbook of that skip rule or failure
│       (skip-spike.md, provider-breaker-open.md)
├── notifications delivered, nobody answered
│   ├── one tenant
│   │   └── its responders are not answering: tell the tenant
│   └── many tenants
│       └── check the response surfaces (links, inbox) are reachable; escalate
└── steps pending or armed with due_at in the past
    └── timer problem: check the maintenance queue, escalate to the agents owners
```

## Mitigation

Relay does not answer, extend or cancel a waitpoint on the tenant's behalf; the waiter owns its deadline. If deliveries fail, mitigate the delivery cause with its own runbook. Tell the tenant which waiter's questions expire unanswered.

## Fix and escalation

The tenant adjusts its deadlines, responders or escalation policy. A Relay fault (escalation timers not firing, response links not reachable) goes to the agents owners with the waitpoint identifiers and times.
