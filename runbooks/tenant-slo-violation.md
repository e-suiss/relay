---
id: tenant-slo-violation
kind: alert
severity: SEV3
channels: [all]
tenant_scope: one
alerts: [RelayTenantSloViolation]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Tenant SLO violation

## Symptom

`relay_slo_tenant_violation_total{channel, severity}` increased in the last hour: a tenant's SLO window on a channel missed its target. The alert is a ticket; it carries the channel and the target's severity, not the tenant.

## Impact

One or a few tenants got a worse service than agreed on that channel. It is a contract matter (credits, account team), not an outage: the installation-wide SLO alerts (slo-accept-burn.md, slo-handoff-burn.md, slo-availability-burn.md) cover the outage side. SEV3; SEV2 when the tenant is a large one and is still affected.

## Diagnosis

Violations of the last day by channel and severity:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (channel, severity) (increase(relay_slo_tenant_violation_total[1d]))' | jq '.data.result'
```

Which tenants had the most failed or slow attempts on the channel in the last day:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT d.tenant_id, count(*) FILTER (WHERE a.state = 'failed') AS failed, count(*) AS attempts FROM relay.delivery_attempts a JOIN relay.deliveries d ON d.tenant_id = a.tenant_id AND d.environment = a.environment AND d.id = a.delivery_id WHERE a.created_at > now() - interval '1 day' AND d.channel = 'email' AND d.environment = 'live' GROUP BY 1 ORDER BY 2 DESC LIMIT 10"
```

Replace `email` with the alert's channel. Map a `tenant_id` to its name with the console's tenant list (`GET /v1/operator/tenants`).

Whether the installation-wide SLOs were burning at the same time:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=ALERTS{alertname=~"RelaySlo.*",alertstate="firing"}' | jq '.data.result[] | .metric'
```

## Decision tree

```text
tenant SLO window missed on channel C
├── installation-wide SLO alerts fired in the same window
│   └── shared cause: handled by that runbook; ticket stays for the account team
├── only this tenant
│   ├── failures are auth/sender_config/quota on its account -> tenant configuration: tell the tenant
│   └── failures are provider-side on its dedicated account -> provider case for that account
└── nothing visible in attempts
    └── Unknown: record it on the ticket and ask engineering to check the tenant SLO computation
```

## Mitigation

No operational step is needed when the cause is over. When a tenant's own configuration still fails, tell the tenant through the account team; nothing is changed on the tenant's behalf. When the tenant has a fallback route configured and its primary provider still fails, the tenant or a tenant administrator switches the route in the console.

## Fix and escalation

Hand the ticket to the tenant's account team with the window, channel and cause. Recurring violations for the same tenant go to the capacity and provider review.
