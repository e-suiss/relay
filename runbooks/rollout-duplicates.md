---
id: rollout-duplicates
severity: SEV2
channels: [push, web_push, in_app]
tenant_scope: tenant
alerts: [RelayRolloutDuplicateWarn, RelayRolloutDuplicateFreeze, RelayRolloutDuplicateRollback]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 15
reversible: true
---

# Duplicate notifications during a rollout

## Symptom

The duplicate rate of displayed notifications (`relay:migration_duplicate_rate:ratio_rate1h`) is above 0.1 percent (warn), 0.5 percent (freeze) or 1 percent (roll back). The SDKs report the digest of every notification they display; a digest reported again for the same subscriber within a day is a duplicate.

## Impact

Subscribers see the same notification twice, once from the existing system and once from Relay. Repeated duplicates erode trust and can count as spam.

## Diagnosis

1. Read `GET /v1/rollout` to see which categories have moved to Relay and when their share last changed.
2. Check that the existing system calls `POST /v1/dedup/claims` with the same dedup key Relay uses before it sends, and that it honours `duplicate`.
3. Check that only one SDK displays notifications in the app; the old SDK's display code must be removed.

## Decision tree

- Rate above 0.1 percent: warn, do not raise any share.
- Rate above 0.5 percent: freeze, no `PUT /v1/rollout` raise until fixed.
- Rate above 1 percent: roll back the affected categories; stop the rollout when the category is not known.

## Mitigation

Lower the affected category's basis points with `PUT /v1/rollout` (a lowering is always allowed and reaches every node within 60 seconds). When the source is unknown, stop the rollout:

```sh state-changing
relay rollout emergency-stop --env live --yes --reason "duplicate rate above threshold"
```

## Fix and escalation

Fix the dedup key rule or the claim call in the existing system, or remove the old SDK's display code. Release the stop with `relay rollout release` once the rate is back under 0.1 percent. Escalate to the tenant's migration owner.
