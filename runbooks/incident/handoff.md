---
id: handoff
kind: incident
last_tested: 2026-11-18
tested_by: none
---

# On-call handoff

## Rules

The handoff is written, every time, using the template below. Active kill switches are read with a live command during the handoff and pasted in; a list from memory or from the previous handoff is never trusted.

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Release.KillSwitch.list())'
```

Run it in every region the on-call covers.

## Template

```markdown
# Handoff <UTC date and time>, <outgoing> -> <incoming>

## Open incidents
| Id | SEV | State | Next step | Next customer update (UTC) |
|---|---|---|---|---|

## Active kill switches (live output, per region)
<paste the output of Relay.Release.KillSwitch.list() here>
For each: why, who approved, when it expires, what reopening needs.

## Alerts during the shift
| Alert | Times | Needed action? | Runbook used |
|---|---|---|---|

## Pages this shift
- Total: <n>; at night: <n>; without action needed: <n>

## Changes in flight
- Deploys, migrations, provider changes, known peaks coming

## Wake-up test
- Last weekly test acknowledged: <date> by <person>

## Read back
- Incoming confirms: "I have the on-call" at <UTC time>
```
