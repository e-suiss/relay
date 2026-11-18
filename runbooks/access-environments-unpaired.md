---
id: access-environments-unpaired
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelayAccessEnvironmentsUnpaired]
last_tested: 2026-11-18
tested_by: none
automation: 2
eta_minutes: 30
reversible: true
---

# Access environments stay unpaired

## Symptom

`RelayAccessEnvironmentsUnpaired` (warning) fires: Access environments of one or more Access tenants stayed unpaired with Relay's service key after three pairing runs in a row. The pairing log names the reason per Access environment. A challenge Relay did not sign is logged with the check it failed: `pairing-kid` (the key registered in Access is not the service key in the key store), `pairing-nonce`, `pairing-register-nonce`, `pairing-validity`, `pairing-pep`, `pairing-basis`, `pairing-instance-intent` or `pairing-register-intent` (Access's intent digest differs from Relay's), `pairing-signature`, and `pairing-signer` when the key store did not answer.

## Impact

The affected Access environments cannot use Relay features that need the paired service instance (Access events of that environment, agent identity resolution). Other tenants and environments are not affected. Already paired environments keep working.

## Diagnosis

Which Access environments are stuck, with Access's refusal code and how many runs failed:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT access_tenant_id, slug, state, refusal_code, failed_runs, updated_at FROM relay.access_pairing_realms WHERE state IN ('unpaired', 'refused') AND failed_runs >= 3 ORDER BY failed_runs DESC"
```

`state = refused` carries Access's code in `refusal_code`; `unpaired` means Relay did not sign or the request failed (read the pairing log line for the `pairing-*` code).

The alarm gauge per node:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=relay_access_pairing_unpaired_access_environments'
```

The service key Relay has, as a JWK with its `kid` thumbprint, to compare with the key registered for Relay's client in Access:

```sh
$RELAY_EXEC bin/relay eval 'Relay.Access.ServiceKey.print_service_key()'
```

Whether the Access link itself is up (pairing needs it):

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Access.link_state())'
```

## Decision tree

```text
environments unpaired after three runs
├── link_state is not :ok
│   └── follow access-link-down.md first
├── log code pairing-kid
│   └── register the printed service key with Relay's client in Access, then re-run (Mitigation)
├── log code pairing-signer
│   └── key store not answering: follow push-signing-unavailable.md (same key store)
├── state = refused with an Access code
│   └── Access refused the pairing: fix on the Access side as the code says, then re-run
└── intent, nonce, validity or signature codes
    └── Access and Relay disagree on the protocol: escalate (Fix and escalation)
```

## Mitigation

Remove the cause, then run the pairing for every tenant now (the hourly run would retry on its own):

```sh state-changing
$RELAY_EXEC bin/relay rpc 'Relay.Access.Pairing.request(:all)'
```

For one tenant use `{:tenant, "tnt_…"}` instead of `:all`. A node queues the same scope at most once every five minutes, so running it twice is harmless.

## Fix and escalation

`pairing-kid` and `refused` are configuration in Access: the Access tenant's administrators or the Access operator fix them. Intent digest, nonce, validity and signature failures mean Relay and Access run incompatible versions: escalate to the Relay and Access engineering on-call with the log lines.
