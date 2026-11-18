---
id: wake-up-budget
kind: alert
severity: SEV4
channels: [none]
tenant_scope: none
alerts: [RelayWakeUpBudget]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Wake-up budget

## Symptom

More than five different alerts paged in the last twelve hours (`ALERTS{alertstate="firing", severity="page"}` counted by alert name). It is a ticket, never a page.

## Impact

No user impact by itself. An on-call engineer who is paged too often stops trusting pages and sleeps through the real one; this alert protects the paging path. SEV4: a planned review.

## Diagnosis

Which alerts paged in the last twelve hours:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=count by (alertname) (max_over_time(ALERTS{alertstate="firing",severity="page"}[12h]))' | jq -r '.data.result[] | .metric.alertname'
```

How long each was firing (minutes with the alert active over 12 hours):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (alertname) (count_over_time(ALERTS{alertstate="firing",severity="page"}[12h]))' | jq '.data.result[] | {alert: .metric.alertname, minutes: .value[1]}'
```

For each page, read the incident record or the on-call handoff note: did it need action, and was the action in its runbook?

## Decision tree

```text
more than five alerts paged in 12 hours
├── one incident caused all of them
│   └── missing grouping or inhibition: add an inhibit rule or group label in Alertmanager
├── a page needed no action
│   └── threshold too low or wrong signal: change the alert or make it a ticket
├── a page fired again and again for minutes
│   └── flapping: add a `for:` duration or hysteresis
└── every page was real and needed action
    └── reliability problem, not alerting: raise it in the weekly review
```

## Mitigation

Nothing to run tonight. Do not silence a paging alert to get under the budget; a silence hides real pages too.

## Fix and escalation

Change the alert rules in `deploy/observability/alerts.yaml` (with their promtool tests and runbooks) through a normal pull request, and record the review in the on-call handoff. Repeated budget breaches are discussed in the weekly operations review.
