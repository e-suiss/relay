---
id: agent-auto-accept
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelayAgentAutoAccept]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Waitpoints answered without reading

## Symptom

`RelayAgentAutoAccept` fires: at least 50 waitpoints were answered in the last hour (`relay_agents_responses_hour`) and the median time from opening to answer is under two seconds (`relay_agents_response_median_milliseconds`). Answers are being given without reading, by a script or by a person who accepts everything.

## Impact

The agents act on answers that carry no human judgement. A response in Relay is evidence of what someone answered, never an authorisation, so no permission is granted by it; but the tenant's own decisions taken on those answers may be wrong. Relay itself is not harmed.

## Diagnosis

The gauges and the evidence levels of recent responses:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_agents_responses_hour or relay_agents_response_median_milliseconds or relay_agents_responses_evidence' | jq -r '.data.result[] | "\(.metric.__name__) \(.metric.level // "") \(.value[1])"'
```

The tenants and surfaces the fast answers come from:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT s.tenant_id, s.environment, s.via, s.evidence_level, count(*), percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM s.responded_at - w.opened_at)) AS median_s FROM relay.waitpoint_responses s JOIN relay.waitpoints w ON w.tenant_id = s.tenant_id AND w.environment = s.environment AND w.id = s.waitpoint_id WHERE s.responded_at > now() - interval '1 hour' GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC LIMIT 20"
```

The responders behind them in one tenant (replace the tenant):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT s.responder_actor_ref, s.responder_recipient_id, s.via, count(*) FROM relay.waitpoint_responses s JOIN relay.waitpoints w ON w.tenant_id = s.tenant_id AND w.environment = s.environment AND w.id = s.waitpoint_id WHERE s.tenant_id = '00000000-0000-0000-0000-000000000000' AND s.responded_at > now() - interval '1 hour' AND s.responded_at - w.opened_at < interval '2 seconds' GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 20"
```

One responder or one API surface (`via`) behind most answers points to a script.

## Decision tree

```text
RelayAgentAutoAccept
├── one responder / one via behind most fast answers
│   └── a script or an auto-accept rule: tell the tenant
├── many responders, one tenant
│   └── the question is built to be clicked through: tell the tenant
└── many tenants at once
    └── possible Relay fault (a link prefetcher counted as an answer):
        escalate to the agents owners
```

## Mitigation

Tell the tenant. Nothing is revoked or undone by Relay: responses are not authorisations, and Relay never cancels or answers a waitpoint on the tenant's behalf.

## Fix and escalation

The tenant reviews the decisions taken on those answers and how the question is asked (require a typed value, a stronger evidence level). If link scanners or prefetchers produce answers, escalate to the agents owners with the responses' `via` and times.
