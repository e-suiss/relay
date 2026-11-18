---
id: rollout-freeze
severity: SEV2
channels: [all]
tenant_scope: installation
alerts: [RelayRolloutQueueFreeze, RelayRollout5xxFreeze, RelayRollout5xxRollback]
last_tested: 2026-11-18
tested_by: none
automation: 0
eta_minutes: 30
reversible: true
---

# Rollout freeze on queue age or server errors

## Symptom

The oldest job of a lane waits more than twice its threshold for ten minutes, or more than 1 percent (freeze) or 5 percent (roll back) of API responses are `5xx` over five minutes.

## Impact

Traffic moved to Relay is delayed or refused; raising the rollout share would make it worse.

## Diagnosis

1. Read `relay_queue_oldest_job_age_seconds` by lane and `relay:http_5xx:ratio_rate5m`.
2. Follow the queue and readiness runbooks for the cause: provider breakers, database, Valkey.
3. Read `GET /v1/rollout` for the shares in force.

## Decision tree

- Queue age above twice the threshold, or `5xx` above 1 percent: freeze, no raise.
- `5xx` above 5 percent: roll back the shares, or stop the rollout.

## Mitigation

Lower the shares with `PUT /v1/rollout`, or stop the rollout:

```sh state-changing
relay rollout emergency-stop --env live --yes --reason "rollout freeze threshold"
```

## Fix and escalation

Fix the cause, then release the stop with `relay rollout release` and raise the shares again by the ramp rule. Escalate to the on-call engineer of the platform.
