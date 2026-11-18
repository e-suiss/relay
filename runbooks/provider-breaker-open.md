---
id: provider-breaker-open
kind: alert
severity: SEV2
channels: [all]
tenant_scope: all
alerts: [RelayProviderBreakerOpen]
last_tested: 2026-11-18
tested_by: none
automation: 2
eta_minutes: 30
reversible: true
---

# Provider breaker open

## Symptom

The provider-level circuit breaker of a provider has been open for ten minutes on at least one node (`relay_breaker_open{provider} == 1`). The provider level counts transport errors, 5xx, timeouts, 429 and unknown failures of every tenant's calls on the node; a tenant's own authentication, sender or quota failures only open that tenant's breaker and never this one.

## Impact

Calls to the provider are rejected on the node without being tried: jobs snooze or fail over to a fallback route. Every tenant on that provider without a fallback waits. When it carries `security`, `transactional` or `action_required` traffic with no fallback, SEV1; otherwise SEV2.

## Diagnosis

Which providers, on how many nodes:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (provider) (relay_breaker_open)' | jq '.data.result'
```

The breaker on the node you exec into (`:open`, `:half_open`, `:closed`, or `nil` when the node never called the provider; replace the provider name):

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Channels.Breaker.provider_state("apns"))'
```

What the provider answered just before the breaker opened:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT failure_class, raw_code, count(*), max(finished_at) FROM relay.delivery_attempts WHERE provider = 'apns' AND finished_at > now() - interval '30 minutes' AND state IN ('failed', 'unknown') GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 10"
```

Dead letters building up for the provider:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT dlq_class, state, count(*) FROM relay.dead_letters WHERE provider = 'apns' AND created_at > now() - interval '2 hours' GROUP BY 1, 2"
```

Whether the provider's status page announces an incident is checked in the browser; when it does, `RelayProviderIncident` groups this alert under it (provider-incident.md).

## Decision tree

```text
provider breaker of P open for 10 minutes
├── P's status page reports an incident
│   └── provider-incident.md
├── failures are timeouts/transport from all nodes
│   ├── other providers fine -> P down or unreachable: fail over, open a provider case
│   └── all providers failing -> our egress (proxy, DNS, network): fix egress first
├── failures are 429
│   └── we exceed P's rate: do NOT add nodes; capacity-incident.md, step "provider capacity"
└── open on one node only
    └── that node's network: drain or restart that node
```

## Mitigation

Fail over to the fallback provider in the console route editor when the route has one. When the breaker is open on one node only, restart that node (Kubernetes example; take the pod name from `kubectl get pods`):

```sh state-changing
kubectl delete pod relay-all-7c9d8b6f5-abcde
```

When the breaker closes, the provider's open `exhausted` dead letters of the last 30 minutes are replayed automatically (`Relay.Delivery.DeadLetters.AutoReplay`); nothing to do by hand. Older dead letters stay open for the tenant to decide.

## Fix and escalation

Open a case with the provider with the raw codes and times. When 429 is the cause, ask for a higher limit before the next peak and plan it in capacity-incident.md. Escalate egress problems to the network owner.
