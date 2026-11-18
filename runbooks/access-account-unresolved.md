---
id: access-account-unresolved
kind: alert
severity: SEV3
channels: [all]
tenant_scope: one
alerts: [RelayAccessAccountUnresolved]
last_tested: 2026-11-18
tested_by: none
automation: 2
eta_minutes: 30
reversible: true
---

# Access account event could not be applied

## Symptom

`RelayAccessAccountUnresolved` opens a ticket: in the last hour Access sent `account.suspended`, `account.reactivated` or `account.deleted` naming the person only by the `usr_` id of the Access account. No Access interface maps that id to the pairwise `sub` Relay knows the person by, so the receipt was recorded with reason `not_applied_account_unresolved` and changed nothing.

## Impact

For that one person: an operator of this installation keeps their Relay sessions and roles, and subscribers whose `external_id` is the person's `sub` are not suspended or reactivated. Access still refuses the person's next sign-in itself, so a suspended operator cannot start a new session. Other people and tenants are not affected.

## Diagnosis

How many events and of which kind:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (kind) (increase(relay_access_event_unresolved_total[1h]))'
```

The receipts, with their Access tenant and the event's identifiers:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT id, event_type, access_tenant_id, received_at, payload->>'jti' AS jti FROM relay.access_event_receipts WHERE reason = 'not_applied_account_unresolved' AND received_at > now() - interval '1 day' ORDER BY received_at DESC"
```

Find the account in the Access console of that Access tenant with the `usr_` id in the payload, and decide whether the person is an operator of this installation, a subscriber of a tenant, or both.

## Decision tree

```text
account event unresolved
├── kind = suspended or deleted
│   ├── person is an operator of this installation
│   │   └── revoke their role assignments by hand (Mitigation 1)
│   └── person is a subscriber
│       └── tenant administrator suspends the subscriber (Mitigation 2)
├── kind = reactivated
│   └── tenant administrator resumes the subscriber if it was suspended for this person
└── person unknown to Relay
    └── nothing to do; close the ticket
```

## Mitigation

Both steps are taken in the operator console, which asks for a step-up and records the audit entry; the console calls the operator API shown in brackets:

1. Operator of this installation: revoke each of their role assignments (`POST /v1/operator/role_assignments/{role_assignment_id}/revoke`, installation operator).
2. Subscriber: a tenant administrator of that tenant suspends the subscriber (`POST /v1/operator/subscribers/{subscriber_id}/suspend`) or, for `reactivated`, resumes it (`/resume`).

Both calls take an `Idempotency-Key`, so repeating them is safe. Relay has no command that applies the Access event itself.

## Fix and escalation

Ask the Access team to carry the person's pairwise `sub` for Relay in account events; until Access does, every such event needs this manual step. Escalate to SEV2 if a deleted or suspended person still holds installation operator roles and cannot be reached.
