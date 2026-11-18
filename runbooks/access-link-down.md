---
id: access-link-down
kind: alert
severity: SEV1
channels: [all]
tenant_scope: all
alerts: [RelayAccessLinkDown]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Access link down

## Symptom

`RelayAccessLinkDown` pages: the node's Access link is not `ok`. Its state is one of:

- `pending`: no successful fetch of the Access discovery documents and key set yet, since the node started. Token verification answers `service_unavailable`.
- `stale`: the last refresh failed; the last key set is still used.
- `region_mismatch`: Access names another region than this installation; the link holds no keys.

The node logs `Access link not refreshed`, `Access link not established` or `Access link refused: Access serves another region`.

## Impact

`pending` and `region_mismatch`: every request that needs an Access token (server API, operator console, CLI) fails closed, for all tenants; delivery of already accepted work goes on. `stale`: requests keep working with the old keys until Access rotates its keys; then tokens signed with the new key are refused. Relay never decides authorisation on its own, so it cannot work around Access.

## Diagnosis

The node's link state:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Access.link_state())'
```

The durable link row every node reads:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT issuer, state, access_region, fetched_at, jwks_fetched_at, updated_at FROM relay.access_link"
```

An old `fetched_at` with state `stale` means refreshes fail; `access_region` different from this installation's region means `region_mismatch`.

Whether Access answers from the node's network (the issuer is in the row above):

```sh
curl -fsS "https://access.example.com/.well-known/openid-configuration"
```

The refresh task's lease:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT leader_node, lease_until, updated_at FROM relay.singleton_tasks WHERE name = 'access_link_refresh'"
```

## Decision tree

```text
Access link not ok
├── state = region_mismatch
│   └── wrong issuer configured, or Access moved region: fix the configuration; never override
├── discovery URL does not answer from the node
│   ├── Access itself down: follow Access's own incident, Relay waits
│   └── network, DNS or TLS problem between Relay and Access: fix it, then refresh (Mitigation)
├── discovery answers, access_link_refresh lease expired
│   └── follow singleton-leaderless.md
└── discovery answers, lease held, state still stale
    └── refresh now (Mitigation) and read the node log for the error code
```

## Mitigation

Fetch and record the discovery documents and keys now (every node re-reads the row on the signal):

```sh state-changing
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Access.refresh())'
```

Re-read `link_state()`: it should be `:ok`. Running it twice is safe.

## Fix and escalation

If Access is down, follow the Access runbooks and escalate to the Access on-call; Relay recovers by itself on the next refresh (every five minutes). For `region_mismatch`, escalate to the installation owner: the region of an installation never changes, so the configured issuer is wrong. Declare SEV1 while server API requests fail.
