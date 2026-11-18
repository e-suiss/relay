---
id: declaration
kind: incident
last_tested: 2026-11-18
tested_by: none
---

# Declaring an incident

## Declare early

Declare as soon as any answer below is "yes" or "not sure". Declaring and standing down costs minutes; declaring late costs the response targets in `severity.md`.

1. Do users feel it (late, missing, wrong or duplicate messages; API errors)?
2. Is a second team needed (database, platform, a provider, compliance, the tenant's account team)?
3. Will it take longer than an hour to resolve?
4. Has something irreversible happened (messages sent that cannot be recalled, tokens disabled, a bulk cancel)?
5. Is a provider account at risk (complaint or bounce rate near the provider's limit, a warning from the provider, a suspension)?

## How

1. Open the incident record in the incident tracker (not in Relay): title, severity from `severity.md`, the UTC time it started and the time it was declared.
2. Page the incident commander for SEV1 and SEV2 (`roles.md`).
3. Open one incident channel; every decision and command run goes there with its UTC time.
4. Read the active kill switches with a live command and paste the output into the channel:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Release.KillSwitch.list())'
```

5. Start the matching runbook. A mass mis-send always starts with `../mass-mis-send.md`.
6. If customers are affected, the communications lead starts `customer-notification.md` against the severity's first notification target.

## Standing down

The incident commander closes the incident when the service is restored and no kill switch is left engaged by mistake. Record the end time, the final severity and whether a postmortem is required (`postmortem.md`).
