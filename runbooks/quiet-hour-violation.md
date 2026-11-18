---
id: quiet-hour-violation
kind: alert
severity: SEV1
channels: [all]
tenant_scope: some
alerts: [RelayQuietHourViolation]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 10
reversible: true
---

# Quiet hour violation

## Symptom

`RelayQuietHourViolation` pages: in the last ten minutes at least one delivery on a channel was handed off to the provider inside the recipient's quiet hours (`relay_policy_quiet_hour_violation_total{channel}`). The policy lattice should have deferred it with `quiet_hours.deferred` or held it in a quiet hours digest window.

## Impact

A message reached a person at a time the law or their own preference forbids. The send cannot be recalled. Legal exposure makes this at least SEV1 whatever the count; more sends follow as long as the cause stays, typically for every recipient of the affected tenant, channel and time zone.

## Diagnosis

Which channels violate and how many sends so far:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (channel) (increase(relay_policy_quiet_hour_violation_total[1h]))' | jq -r '.data.result[] | "\(.metric.channel) \(.value[1])"'
```

Deliveries that were deferred by quiet hours but reached the provider before the end of their deferral, by tenant:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT d.tenant_id, d.environment, d.channel, count(*) FROM relay.deliveries d JOIN relay.delivery_attempts a ON a.tenant_id = d.tenant_id AND a.environment = d.environment AND a.delivery_id = d.id WHERE d.decision_rule_id = 'quiet_hours.deferred' AND a.started_at < d.deferred_until AND a.created_at > now() - interval '6 hours' GROUP BY 1, 2, 3 ORDER BY 4 DESC"
```

Rows here name the tenant and channel to stop. No rows while the alert fires means the delivery was never deferred at all: the lattice did not see the quiet hours (a missing time zone, a fallback time zone, a preference not loaded).

The tenant's external identifier for the kill switch (replace the UUID):

```sh
$RELAY_EXEC bin/relay eval 'IO.puts(Relay.ExternalId.encode("ten", elem(Relay.Id.parse("00000000-0000-7000-8000-000000000000"), 1)))'
```

Recent deploys and data set changes (time zones, delivery windows) are the usual cause when several tenants appear at once.

## Decision tree

```text
RelayQuietHourViolation
├── one tenant (and channel) in the query
│   └── kill switch on that tenant × channel (Mitigation 1), then find the cause
├── several tenants, same channel
│   └── kill switch per tenant × channel; if more than a few, escalate for a
│       platform-scope decision (incident commander decides)
└── no rows in the deferral query
    ├── a deploy landed in the last hour
    │   └── stop the affected scope (Mitigation 1) and roll the deploy back
    └── no deploy
        └── stop the affected scope; escalate to the policy owners with the channel
```

## Mitigation

Stop first. Engage a kill switch on the affected tenant and channel for the classes that respect quiet hours (here `marketing`; repeat with `social` if those violated too). It pauses queued deliveries and holds new ones; nothing is lost:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"quiet hour violation\", ttl: \"4h\", scope: :tenant, tenant: \"ten_REPLACE\", environment: :live, channel: \"sms\", message_class: \"marketing\"))"
```

Read it back to confirm it is in force (and hand it over at shift change):

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Release.KillSwitch.list())'
```

If many tenants are affected, follow `mass-mis-send.md` for the stop-first procedure and the staged reopening. Releasing the kill switch is a decision of the incident commander with the compliance lead, never automatic; the release needs `confirm_relax:` with that approval reference.

## Fix and escalation

Find why the lattice let the send through: the recipient's time zone (the fallback time zone source in the delivery's decision), the tenant's quiet hours preference, the `delivery_windows` data set version. Fix and verify in the `test` environment before reopening. Escalate to the compliance lead at once: a quiet hour breach is a legal event and needs its own assessment and record. A postmortem is mandatory.
