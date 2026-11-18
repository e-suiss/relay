---
id: agent-reply-drop
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelayAgentReplyDrop]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Agent reply drop

## Symptom

`RelayAgentReplyDrop` fires: over the last hour the share of agent messages that got a reply (`relay_agents_message_total{direction="reply"}` against `direction="sent"`) is less than half of the same hour yesterday, while the number of agent messages sent grew. Agents are sending more and people are answering less.

## Impact

The pattern of an agent that spams: recipients stop engaging, start ignoring or refusing, and the tenant's sender reputation on the channel suffers. Nothing is lost in Relay; the harm is to recipients' attention and to the tenant's reputation, and it grows with every hour the volume stays up.

## Diagnosis

Agent messages sent and replies received now, against yesterday:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (direction) (increase(relay_agents_message_total[1h]))' | jq -r '.data.result[] | "\(.metric.direction) \(.value[1])"'
```

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (direction) (increase(relay_agents_message_total[1h] offset 1d))' | jq -r '.data.result[] | "\(.metric.direction) \(.value[1])"'
```

Which tenants and senders the extra agent notifications come from in the last hour:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, environment, count(*) FROM relay.notifications WHERE sender_type = 'agent' AND created_at > now() - interval '1 hour' GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20"
```

Compare with the same hour yesterday by changing the interval; a tenant that doubled is the one to look at. The agents near their ceiling show up as held notifications:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, environment, agent_ref, state, count(*) FROM relay.agent_ceiling_holds WHERE created_at > now() - interval '1 day' GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC LIMIT 20"
```

## Decision tree

```text
RelayAgentReplyDrop
├── one tenant's agent notifications grew sharply
│   ├── its agents are already held at their ceiling
│   │   └── the ceiling bounds it; tell the tenant, the owner decides on the holds
│   └── below the ceiling
│       └── tell the tenant; suggest lowering agents.ceiling.per_hour / per_day
├── growth spread across many tenants
│   └── likely a shared cause (a new integration, a deploy): escalate to the agents owners
└── replies dropped but volume normal
    └── a reply intake problem: check inbound provider events and the mailboxes
```

## Mitigation

Relay does not stop a tenant's agent on its behalf for low engagement. The agent ceiling already bounds how much each agent can send; the tenant's owner can lower it, or stop the agent through `POST /v1/agents/{agent_id}/ceiling_decisions` with `stop`. If the volume is abuse that harms other tenants or a shared sender reputation, the installation operator stops the tenant's agent traffic with a tenant kill switch under the usual approval (see `mass-mis-send.md`).

## Fix and escalation

The tenant fixes its agent's sending logic. A reply intake fault in Relay (inbound events not matched, mailboxes not written) goes to the agents owners with the channel and the first hour replies fell.
