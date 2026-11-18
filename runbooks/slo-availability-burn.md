---
id: slo-availability-burn
kind: alert
severity: SEV2
channels: [all]
tenant_scope: some
alerts: [RelaySloAvailabilityFastBurn, RelaySloAvailabilitySlowBurn, RelaySloAvailabilityBudgetBurn]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Provider acceptance SLO burn

## Symptom

The share of attempts a provider accepts (`relay_slo_availability_total{class, channel, provider, good}`, from the ledger's `attempt.succeeded`, `attempt.failed` and `attempt.unknown`) is under the class's availability target fast enough to burn the budget 14.4x (page), 6x (page) or 1x over three days (ticket).

## Impact

Attempts fail at the provider. Retries absorb short blips; longer failures turn into dead letters and undelivered messages for every tenant on that provider. `security`, `transactional` or `action_required` not being sent is SEV1; `marketing` only is SEV2; a ticket burn is SEV3.

## Diagnosis

Which class, channel and provider:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay:slo_availability_errors:ratio_rate5m > 0' | jq '.data.result[] | {class: .metric.class, channel: .metric.channel, provider: .metric.provider, ratio: .value[1]}'
```

Failures of the last 15 minutes by failure class and raw provider code:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT provider, failure_class, raw_code, count(*) FROM relay.delivery_attempts WHERE finished_at > now() - interval '15 minutes' AND state IN ('failed', 'unknown') GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 20"
```

What the classes mean for the decision:

- `auth`, `sender_config` or `quota` on one tenant's account: that tenant's credentials, sender setup or quota; other tenants are fine.
- `transient` or `unknown` across tenants: the provider itself.
- `permanent_target`: bad addresses or tokens, usually one sender's list.
- `permanent_content` or `policy`: the provider refuses the content (template change, missing approval).

Provider breaker state (1 = open):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (provider) (relay_breaker_open)' | jq '.data.result'
```

Failures spread across tenants or concentrated in one:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, provider_account_id, count(*) FROM relay.delivery_attempts WHERE finished_at > now() - interval '15 minutes' AND state = 'failed' GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 10"
```

## Decision tree

```text
availability burning for class C on P
├── failures concentrated on one provider account
│   ├── auth or sender_config failure class -> tenant credentials: tell the tenant, rotate in the console
│   └── quota -> tenant's provider quota: tell the tenant
├── failures across tenants
│   ├── provider status page reports an incident -> provider-incident.md
│   ├── breaker open -> provider-breaker-open.md
│   └── neither -> provider-side errors unannounced: open a provider case, fail over if possible
└── only RelaySloAvailabilityBudgetBurn (ticket)
    └── review the rejection trend with the provider
```

## Mitigation

Fail over to a fallback provider in the console route editor when one is configured. When one provider account sends an abnormal volume of `permanent_target` failures (a bad list), stop that account's traffic with a provider account kill switch (`PROVIDER_ACCOUNT_UUID` is `provider_account_id` from the query above):

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"provider rejections\", ttl: \"2h\", scope: :tenant, tenant: \"ten_REPLACE\", environment: :live, target: {:provider_account, \"PROVIDER_ACCOUNT_UUID\"}))"
```

## Fix and escalation

Configuration rejections are fixed by the tenant (credentials, sender identity, templates). Provider faults are reported to the provider with the raw codes above. A raw code without a mapping is handled in unknown-provider-code.md.
