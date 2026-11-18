---
id: unknown-provider-code
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelayUnknownProviderCode]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Unknown provider code

## Symptom

A provider returned a code that its adapter has no mapping for (`relay_provider_unknown_code_total{channel, provider}`). Relay classifies the attempt `unknown`, never guesses, appends a `provider.unknown_code` event with the raw code and logs `a provider code has no mapping; classified unknown`.

## Impact

The affected attempts follow the provider's policy for uncertain outcomes instead of the right retry or stop decision: a permanent error may be retried, a target that should be disabled stays active. Usually a handful of messages; SEV3. SEV2 when the volume is large or the code is new across all tenants (a provider API change).

## Diagnosis

Which codes, how many, per provider (from the outbox events of the last day):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT payload->>'provider' AS provider, payload->>'channel' AS channel, payload->>'raw_code' AS raw_code, count(*), max(created_at) FROM relay.outbox_events WHERE event_type = 'provider.unknown_code' AND created_at > now() - interval '1 day' GROUP BY 1, 2, 3 ORDER BY 4 DESC"
```

The same raw codes in the ledger, with the attempts' failure class:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT provider, raw_code, failure_class, count(*) FROM relay.delivery_attempts WHERE finished_at > now() - interval '1 day' AND failure_class = 'unknown' GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 20"
```

Rate over time, to tell a burst from a steady new code:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (channel, provider) (increase(relay_provider_unknown_code_total[1h]))' | jq '.data.result'
```

## Decision tree

```text
provider P reports unmapped code X
├── X documented by P
│   └── add the mapping to the adapter's code map and release it
├── X undocumented, few occurrences
│   └── ask P what X means; keep the ticket open
└── many occurrences across tenants, new since today
    └── provider API change: check P's changelog and status page, raise to SEV2
```

## Mitigation

Nothing to stop: unknown outcomes are handled conservatively. If a burst of unknown outcomes comes with paid channel retries (SMS, voice) that cost money, a tenant administrator can stop the affected flow with a scoped kill switch from the console.

## Fix and escalation

Add the code with its failure class to the provider's code map (the adapter mapping, or the provider's bounce code data set for e-mail) through a normal change and release. Escalate unclear codes to the provider's support.
