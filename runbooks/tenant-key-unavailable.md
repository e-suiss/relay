---
id: tenant-key-unavailable
kind: alert
severity: SEV2
channels: [all]
tenant_scope: one
alerts: [RelayTenantKeyUnavailable]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Tenant key unavailable

## Symptom

`RelayTenantKeyUnavailable` pages. Requests of one tenant that need its encrypted data fail with `key_unavailable` (HTTP 503); sends, subscriber reads and exports of that tenant stop while other tenants are unaffected.

## Impact

One tenant that brought its own key cannot read its encrypted data: deliveries that need a recipient's address or content wait, and the tenant's API answers `key_unavailable`. Nothing is lost while the key object exists; if the tenant destroyed it, its data is crypto-shredded for good.

## Diagnosis

1. Read the tenant's key reference with the operator API: `GET /v1/operator/tenants/{tenant_id}/key_custody`.
2. Check that the key store program answers (`GET /v1/operator/region_health`, check `key_store`).
3. List the token's objects with the region's PKCS#11 tool and look for the object label of the reference.
4. Ask the tenant whether it withdrew, disabled or destroyed the key.

## Decision tree

- The key store program is down for every tenant: follow the key store runbook; this alert is a consequence.
- The token is reachable but the object is missing and the tenant withdrew it by mistake: the tenant restores the key in the region's HSM under the same label.
- The tenant destroyed the key on purpose: the tenant's data is crypto-shredded; record it and start the tenant closure if the tenant asks for it.
- The object exists but is not usable for wrapping (attributes changed): the tenant restores the attributes; Relay needs unwrap and wrap on it.

## Mitigation

Nothing in Relay can read the tenant's data without its key; reads stay closed. Keep the tenant informed through the operations contact.

## Fix and escalation

Once the key is back, reads resume without a restart: the next read unwraps the tenant's keys again. If the tenant moves to a new key, the installation operator sets it with step-up:

```sh state-changing
curl -fsS -X PUT "$RELAY_URL/v1/operator/tenants/$TENANT/key_custody" -H "authorization: DPoP $TOKEN" -H "dpop: $PROOF" -H "idempotency-key: $(uuidgen)" -H "content-type: application/json" -d '{"key_ref": "pkcs11:token=region;object=tenant-key"}'
```

Escalate to the security owner when the key disappeared without the tenant's action.
