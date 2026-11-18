---
id: kill-switch-emergency
kind: procedure
severity: SEV1
channels: [all]
tenant_scope: all
alerts: []
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 10
reversible: true
---

# Kill switch: the three ways in

## Symptom

Sending has to stop now (a mass mis-send, a compliance breach, a provider account at risk) and the usual way to stop it, the console, does not work: it does not load, the operator session cannot be started because Access is down, or the API answers errors.

## Impact

Until the kill switch holds, every queued and newly accepted message in the scope keeps going out. Each minute adds recipients who cannot be un-sent. A platform kill switch stops every tenant of the installation; prefer the narrowest scope that stops the harm (tenant, campaign, workflow, sender, channel or provider account).

## Diagnosis

There are three independent ways to write a kill switch. All of them write the same `relay.kill_switches` record through `relay_fn.kill_switch_engage` and the same `killswitch.engaged` audit record, so use the first one that works.

1. Console or operator API (`POST /v1/operator/kill_switches`): the normal way. Use it if it loads.
2. Release command inside a running Relay node: needs a node, not the API, the console or Access.
3. Direct database procedure: needs only PostgreSQL. Use it when no node answers.

Is a node reachable?

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Release.KillSwitch.list())'
```

A list (`{:ok, %{kill_switches: [...]}}`) means way 2 works and also shows what is already in force. An error or a timeout means use way 3.

Is the database reachable with the application role?

```sh
psql "$DATABASE_URL" -Atc "SELECT relay_private.installation_tenant_id(), now()"
```

## Decision tree

```text
must stop sending now
├── console loads and the session works
│   └── way 1: console > Governance > Kill switches > Engage
├── a node answers bin/relay rpc
│   └── way 2: release command (Mitigation A)
└── no node answers
    ├── PostgreSQL answers
    │   └── way 3: database procedure (Mitigation B, steps B1 to B4)
    └── PostgreSQL does not answer
        └── nothing is being sent either: nodes cannot claim jobs;
            stop the nodes themselves (Mitigation C) and escalate
```

## Mitigation

### A. Release command in a running node

Platform scope, every message class, two hours (narrow it with `scope: :tenant, tenant: "ten_…", environment: :live`, `channel:`, `message_class:` or `target:` as listed in the `Relay.Release.KillSwitch.engage/1` docs):

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"emergency stop\", ttl: \"2h\", scope: :platform))"
```

`{:ok, %{result: :engaged, …}}` means it is written, signalled and the sweep that pauses queued deliveries is queued. Running it twice writes a second record of the same stop: harmless, both hold the same scope; release the extra one when reopening.

### B. Direct database procedure

B1. Name the record and the installation (read-only; prints two UUIDs):

```sh
psql "$DATABASE_URL" -Atc "SELECT relay_private.installation_tenant_id(), uuidv7()"
```

Set them in your shell, together with the reason you will write (the same text must go to every step):

```sh
export KS_TENANT=<first uuid> KS_ID=<second uuid> KS_REASON="emergency stop"
```

B2. Compute the audit record digest. This is a pure function: any container of the Relay release image with the installation's environment can run it, a running node is not needed (for example `docker run --rm --env-file relay.env --entrypoint /app/bin/relay ghcr.io/e-suiss/relay:<version> eval "…"`):

```sh
$RELAY_EXEC bin/relay eval "IO.puts(Base.encode16(Relay.Audit.record_digest(%{tenant_id: Base.decode16!(String.replace(\"$KS_TENANT\", \"-\", \"\"), case: :lower), environment: \"live\", action: \"killswitch.engaged\", actor_kind: \"installation_operator\", actor_ref: \"$RELAY_OPERATOR\", on_behalf_of_ref: \"$RELAY_OPERATOR\", target_type: \"kill_switch\", target_id: \"$KS_ID\", reason: \"$KS_REASON\"}), case: :lower))"
```

```sh
export KS_DIGEST=<the 64 hex characters it printed>
```

B3. Write the kill switch: platform scope, every channel and class, state `off`, expires in two hours. The function checks the scope, writes the record and its audit record and announces it in the outbox, in one transaction:

```sh state-changing
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --single-transaction -c "SELECT set_config('relay.tenant_id', '$KS_TENANT', true), set_config('relay.environment', 'live', true)" -c "SELECT * FROM relay_fn.kill_switch_engage('$KS_ID', 'platform', NULL, NULL, 'all', NULL, NULL, NULL, 'off', NULL, NULL, '$KS_REASON', NULL, now() + interval '2 hours', NULL, 'operator', decode('$KS_DIGEST', 'hex'), 'installation_operator', '$RELAY_OPERATOR', '$RELAY_OPERATOR', NULL)"
```

`engaged` with a `generation` means it is written. `exists` means this `KS_ID` was already written (running it twice is safe). Any other result names what was refused.

B4. Tell the nodes at once (without the signal they read the new state within 30 seconds anyway; use the `generation` B3 printed):

```sh state-changing
valkey-cli -u "$VALKEY_URL" PUBLISH relay:s:signal:killswitch 42
```

Every send job reads its node's kill switch state before it hands a message to a provider, so the stop holds from here. The deliveries already queued are marked `paused` by the sweep that ways 1 and 2 queue; after way 3, engage the same scope again through way 1 or 2 as soon as a node answers (it writes a second record of the same stop and queues the sweep; release the extra record when reopening).

### C. No database, no nodes

Scale the Relay deployment to zero so that nothing resumes sending before you are ready:

```sh state-changing
kubectl scale deploy/relay-all --replicas=0
```

## Fix and escalation

Record the kill switch id, the path used and the minute it held in the incident log. Read the active kill switches with a live command (`Relay.Release.KillSwitch.list()`), never from memory, at every handoff. Releasing or relaxing needs an approval reference (`confirm_relax:`) and follows the staged reopen in `mass-mis-send.md`. Escalate to the incident commander (`incident/roles.md`) when way 3 was needed: the console or Access outage is its own incident.
