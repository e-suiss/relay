---
id: subscriber-token-key-rotation
kind: alert
severity: SEV4
channels: [in_app]
tenant_scope: all
alerts: [RelaySubscriberTokenKeyRotationDue]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: false
---

# Subscriber token key rotation due

## Symptom

`RelaySubscriberTokenKeyRotationDue` opens a ticket: the P-256 key that signs subscriber tokens (inbox, realtime and client SDK sessions) has been the current key for more than 90 days, the rotation period.

## Impact

Nothing fails. An old key widens the window in which a leaked key could sign tokens. The rotation is planned work, done in working hours.

## Diagnosis

The current key, its activation, when rotation is due and the previous key's verification window:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Release.SubscriberTokenKey.status())'
```

The activation time Prometheus sees:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max(relay_access_subscriber_token_key_activated_timestamp_seconds)'
```

The key pairs in the key store, by their public halves (private keys never leave it):

```sh
pkcs11-tool --module "$PKCS11_MODULE" --token-label "$PKCS11_TOKEN" --list-objects --type pubkey
```

## Decision tree

```text
rotation due
├── a previous key is still in its verification window
│   └── a rotation ran recently; wait until the window closes, then rotate
├── key compromise suspected
│   └── rotate (Mitigation 1 and 2), then retire the previous key at once (Mitigation 3)
└── routine
    └── create the new key pair (Mitigation 1), rotate to it (Mitigation 2)
```

## Mitigation

1. Create the new P-256 key pair in the key store under a new label (the script skips keys that exist; set the same `PKCS11_*` and `KEY_STORE_*` variables you used when the installation was created):

```sh state-changing
KEY_STORE_SUBSCRIBER_TOKEN_LABEL=subscriber-token-2027-03 deploy/hsm-keys.sh
```

2. Make it the current key; the previous key keeps verifying for two token lifetimes, so open sessions continue:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.SubscriberTokenKey.rotate(label: \"subscriber-token-2027-03\", operator: \"$RELAY_OPERATOR\", reason: \"90-day rotation\"))"
```

3. Only on suspected compromise: retire the previous key now. Its tokens stop verifying and their realtime connections close, so clients sign in again:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.SubscriberTokenKey.retire_previous(operator: \"$RELAY_OPERATOR\", reason: \"suspected compromise\"))"
```

Run `status()` again: the new label is current and the activation is now.

## Fix and escalation

A routine rotation needs no escalation. On suspected compromise, declare a security incident (see `incident/`) and escalate to the installation's security owner; the rotation itself cannot be undone, only followed by another rotation.
