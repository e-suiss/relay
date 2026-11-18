---
id: iys-direct-access
kind: alert
severity: SEV3
channels: [sms, voice, email]
tenant_scope: one
alerts: [RelayIysDirectAccessWarning, RelayIysDirectAccessReached]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# İYS direct access threshold

## Symptom

`RelayIysDirectAccessWarning` fires when a brand that connects to İYS through an integrator holds more than 80% of the 250 000 distinct addresses above which İYS expects a direct connection (`relay_iys_direct_access_warning_brands > 0`). `RelayIysDirectAccessReached` fires when the brand reached the threshold (`relay_iys_direct_access_reached_brands > 0`).

## Impact

Nothing stops in Relay. The tenant is approaching or past the size at which İYS expects it to hold its own İYS API access instead of going through an integrator; staying on the integrator past the threshold is the tenant's regulatory exposure, not a delivery fault.

## Diagnosis

Brands at the warning or at the limit, with their address count and connection mode:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT s.tenant_id, s.environment, b.brand_code, b.name, s.address_count, s.address_state, c.mode FROM relay.iys_sync_states s JOIN relay.iys_brands b ON b.tenant_id = s.tenant_id AND b.environment = s.environment AND b.id = s.brand_id JOIN relay.iys_configs c ON c.tenant_id = s.tenant_id AND c.environment = s.environment WHERE s.address_state <> 'ok' ORDER BY s.address_count DESC"
```

`address_state` is `warning` or `reached`; `mode` is `integrator` for the brands this alert concerns. The address count is refreshed by the reconciliation, so it may lag by up to one reconciliation interval.

The tenant's external identifier for the message to its account team (replace the UUID):

```sh
$RELAY_EXEC bin/relay eval 'IO.puts(Relay.ExternalId.encode("ten", elem(Relay.Id.parse("00000000-0000-7000-8000-000000000000"), 1)))'
```

## Decision tree

```text
RelayIysDirectAccessWarning / Reached
├── address_state = warning
│   └── tell the tenant to prepare its own İYS API access
└── address_state = reached
    ├── tenant already preparing
    │   └── agree a switch date; track it
    └── tenant not aware
        └── tell the tenant and its account team; record the date told
```

## Mitigation

Nothing to stop and nothing Relay changes by itself. Tell the tenant through its account team.

## Fix and escalation

The tenant obtains its own İYS access and replaces its İYS configuration with mode `own` (`PUT /v1/iys/config` with the new credential); the next synchronisation uses it. Escalate to the compliance lead if a tenant past the threshold does not plan the switch.
