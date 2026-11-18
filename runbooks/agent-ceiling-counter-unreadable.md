---
id: agent-ceiling-counter-unreadable
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelayAgentCeilingCounterUnreadable]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Agent ceiling counter unreadable

## Symptom

`RelayAgentCeilingCounterUnreadable` fires: in the last 15 minutes agent notifications were held with `agent_ceiling.counter_unreadable` (`relay_agents_ceiling_held_total{reason="counter_unreadable"}`). Neither Valkey nor the PostgreSQL fallback could read the agent ceiling counter, and the ceiling fails closed.

## Impact

Notifications sent by agents are held, paused and never failed or deleted, waiting for their owner's decision. Notifications of human and system senders are not affected. Every agent of every tenant whose counter could not be read is affected while the backend is away; the holds stay after the backend returns until each owner decides.

## Diagnosis

Holds by reason and the held and open-event gauges:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (reason) (increase(relay_agents_ceiling_held_total[1h]))' | jq -r '.data.result[] | "\(.metric.reason) \(.value[1])"'
```

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_agents_ceiling_held or relay_agents_ceiling_open_events' | jq -r '.data.result[] | "\(.metric.__name__) \(.value[1])"'
```

Is Valkey reachable and answering:

```sh
valkey-cli -u "$VALKEY_URL" PING
```

`PONG` means Valkey answers now; a timeout or a refused connection means it is away. Is PostgreSQL reachable:

```sh
pg_isready -d "$MAINT_DATABASE_URL"
```

The node's own view of its dependencies:

```sh
curl -fsS "$RELAY_URL/readyz"
```

Held notifications by tenant and agent:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, environment, agent_ref, count(*), min(held_at) FROM relay.agent_ceiling_holds WHERE state = 'held' AND rule_id = 'agent_ceiling.counter_unreadable' GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 20"
```

## Decision tree

```text
RelayAgentCeilingCounterUnreadable
├── Valkey PING fails
│   ├── PostgreSQL also unreachable
│   │   └── wider outage: follow valkey-loss.md and postgres-failover.md
│   └── PostgreSQL fine
│       └── fallback should have read: escalate to the agents owners;
│           restore Valkey (valkey-loss.md)
├── Valkey PING fine, holds still growing
│   └── node-to-Valkey path or rate counter fault: check the nodes' logs, escalate
└── holds stopped growing
    └── backend back: tell the owners of the held notifications
```

## Mitigation

Restore the counter backend first (Valkey, or the PostgreSQL connection). The held notifications are not released by themselves and the on-call operator does not release them: each agent's owner got `agent.ceiling_exceeded` and decides with `POST /v1/agents/{agent_id}/ceiling_decisions` (`send_all`, `cancel` or `stop`); a release needs a step-up on the operator surface. A held notification past its `expires_at` closes as `expired` when released.

## Fix and escalation

Fix the backend failure with its own runbook. Tell the tenants whose agents have holds (the query above) that a decision is waiting. If PostgreSQL was healthy and the fallback still failed, escalate to the agents owners with the hold times.
