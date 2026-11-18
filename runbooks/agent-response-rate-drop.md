---
id: agent-response-rate-drop
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelayAgentResponseRateDrop]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Waitpoint response rate drop

## Symptom

`RelayAgentResponseRateDrop` fires: the share of opened waitpoints that got an answer in the last day (`relay_agents_response_rate_percent`) is 20 points below that of the seven days before (`relay_agents_response_rate_previous_percent`), while at least twice as many waitpoints were opened (`relay_agents_waitpoints_opened_day` against `relay_agents_waitpoints_opened_daily_average`). Responders are being flooded.

## Impact

People asked by agents stop answering because they are asked too much. Decisions wait or fall back to defaults, and the responders learn to ignore the questions, which outlasts the flood. Nothing is lost in Relay.

## Diagnosis

The four gauges:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_agents_response_rate_percent or relay_agents_response_rate_previous_percent or relay_agents_waitpoints_opened_day or relay_agents_waitpoints_opened_daily_average' | jq -r '.data.result[] | "\(.metric.__name__) \(.value[1])"'
```

The waiters that opened the extra waitpoints in the last day, against their daily average of the week before:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, environment, waiter_kind, waiter_ref, count(*) FILTER (WHERE opened_at > now() - interval '1 day') AS last_day, round(count(*) FILTER (WHERE opened_at <= now() - interval '1 day') / 7.0, 1) AS daily_avg FROM relay.waitpoints WHERE kind IN ('question', 'review') AND opened_at > now() - interval '8 days' GROUP BY 1, 2, 3, 4 ORDER BY last_day DESC LIMIT 20"
```

A waiter whose `last_day` is far above its `daily_avg` is the one flooding. `waiter_ref` identifies the agent or API client.

## Decision tree

```text
RelayAgentResponseRateDrop
├── one waiter dominates the extra volume
│   └── tell the tenant that owns it; suggest lowering its limits
├── many waiters in one tenant
│   └── tenant-wide change (a new workflow): tell the tenant
└── spread across tenants
    └── escalate to the agents owners; look for a shared cause
```

## Mitigation

Tell the tenant that owns the waiter. The limits of concurrently open waitpoints per waiter and per environment, and the agent ceiling, already bound the flood; the tenant may lower both. Relay does not cancel waitpoints or stop the agent on the tenant's behalf.

## Fix and escalation

The tenant fixes how often its agent asks and whom. A shared cause across tenants goes to the agents owners with the waiters and the day the volume rose.
