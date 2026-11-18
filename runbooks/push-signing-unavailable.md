---
id: push-signing-unavailable
kind: alert
severity: SEV1
channels: [push]
tenant_scope: all
alerts: [RelayPushSigningUnavailable]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Push signing unavailable

## Symptom

`RelayPushSigningUnavailable` pages: in the last five minutes the key store could not sign an APNs provider token (the ES256 JWT that authenticates Relay to APNs). The key store program may log `key store request timed out; restarting the program`, `key store program exited` or `key store program failed verification`.

## Impact

An APNs provider token stays valid for an hour: Relay reuses a token younger than an hour while signing fails, so push keeps working until the last token expires, then every push to iOS stops for every tenant. Web Push signs its VAPID headers with the same key store and caches them for up to an hour; once the cache runs out its sends are refused with `auth_unavailable` (that path does not feed this alert). The same key store also signs audit checkpoints and subscriber tokens, so other alerts may follow.

## Diagnosis

Failures per node:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (instance) (increase(relay_push_signing_unavailable_total[15m]))'
```

All nodes failing points at the key store (HSM, network to it, PIN); one node points at that node's key store program.

Does the key store answer on a node:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Keys.ping())'
```

`:ok` means the store answers now; an error code names the failure.

The key store configuration the node runs with (module, token label; the PIN is a file, never printed):

```sh
$RELAY_EXEC printenv PKCS11_MODULE PKCS11_TOKEN PKCS11_PIN_FILE
```

Check the HSM or SoftHSM itself with its own tools, for example:

```sh
pkcs11-tool --module "$PKCS11_MODULE" --list-slots
```

## Decision tree

```text
push signing unavailable
├── Relay.Keys.ping() fails on every node
│   ├── HSM unreachable or down: restore it (HSM operator)
│   └── PIN or token changed: fix the secret, restart nodes
├── ping fails on one node only
│   └── restart that node (Mitigation)
└── ping ok but signing still fails
    └── the signing key of that APNs provider account is missing in the store: check the provider account (operator console, provider accounts)
```

## Mitigation

Act within the hour the last APNs token stays valid. When one node fails, restart it so its key store program starts fresh:

```sh state-changing
kubectl delete pod relay-7c9d8b6f5-abcde
```

When the store itself is down, restore the HSM; Relay signs again on the next send without any replay. Deliveries that failed meanwhile follow their normal retry and fallback.

## Fix and escalation

Escalate to the HSM owner at once when every node fails. If the hour runs out, declare SEV1 for `security` and `transactional` push. Keys never leave the HSM, so there is no fallback signing path outside it.
