---
id: provider-incident
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelayProviderIncident]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 20
reversible: true
---

# Provider incident

## Symptom

A provider's status page reports an incident (`relay_provider_incident{provider} == 1`). Alertmanager then inhibits the same provider's breaker, availability, handoff, proven delivery and e-mail event alerts, so this is the one page for it. Unknown: no Relay component sets this gauge in this release, so it only fires where the installation feeds a provider status into it; otherwise the provider's own alerts page instead.

## Impact

Everything that goes through the provider is degraded as the provider describes. The incident is the provider's, but the severity is set by its impact on Relay's messages (a provider incident never lowers the severity, it only changes the escalation path): `security` or `transactional` traffic without a fallback is SEV1.

## Diagnosis

Which provider and since when:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (provider) (relay_provider_incident) == 1' | jq '.data.result'
```

How much traffic of each class is waiting on that provider (replace `apns`):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT n.message_class, d.channel, count(*) FROM relay.deliveries d JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment AND n.id = d.notification_id WHERE d.provider = 'apns' AND d.created_at > now() - interval '1 hour' AND d.delivered_at IS NULL AND d.failure_kind IS NULL GROUP BY 1, 2 ORDER BY 3 DESC"
```

The inhibited alerts that would otherwise page:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=ALERTS{alertstate="firing",provider="apns"}' | jq '.data.result[] | .metric.alertname'
```

## Decision tree

```text
provider P reports an incident
├── P carries security/transactional/action_required traffic
│   ├── fallback route configured -> fail over now (Mitigation)
│   └── no fallback -> SEV1: declare, notify tenants via the status page
├── only marketing/bulk on P
│   └── let retries and the breaker hold traffic; consider pausing large campaigns
└── P's incident resolved, our alerts still firing
    └── follow the provider's own alerts' runbooks (provider-breaker-open.md, esp-events.md)
```

## Mitigation

Fail over to the fallback provider in the console route editor. Large marketing campaigns on the provider can be paused so they do not pile up retries:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"provider incident\", ttl: \"4h\", scope: :campaign, scope_ref: \"cmp_REPLACE\", tenant: \"ten_REPLACE\", environment: :live))"
```

Inform tenants through the status page with the customer notification template in `incident/`, never through Relay.

## Fix and escalation

Follow the provider's incident and keep its reference in the incident record. Escalate through the provider's support channel; nothing on Relay's side fixes their outage. After it ends, release the pauses you engaged and check that dead letters replayed.
