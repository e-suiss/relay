---
id: rollout-unpermitted-send
kind: alert
severity: SEV1
channels: [email, sms, push, whatsapp, voice]
tenant_scope: some
alerts: [RelayRolloutUnpermittedSend]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 5
reversible: true
---

# Send to a recipient without consent during a migration

## Symptom

`relay_shadow_unpermitted_total` grew: a shadow comparison found that one system sent to a recipient whose consent the other system refused or whose address it suppressed.

## Impact

A message may reach someone who did not consent or who is suppressed: a compliance breach. A single case is enough to stop.

## Diagnosis

1. Read `GET /v1/shadow/coverage` and find the template and channel with consent differences.
2. Compare the consent and suppression lists of both systems for the recipients involved; check that the suppressions and consents were imported before any address.

## Decision tree

```text
- Any case: stop the rollout at once.
- The difference is in the existing system's data: fix the import before releasing.
- The difference is in Relay's data: fix it and keep the stop until the coverage report shows no consent difference.
```

## Mitigation

Stop the rollout; the command also opens an incident record:

```sh state-changing
relay rollout emergency-stop --env live --yes --reason "send without consent"
```

## Fix and escalation

Reconcile consents and suppressions, then release with `relay rollout release`. Escalate to the tenant's compliance contact and follow the incident procedure.
