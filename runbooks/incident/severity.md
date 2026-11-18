---
id: severity
kind: incident
last_tested: 2026-11-18
tested_by: none
---

# Severity

This is the only severity table for Relay. Alerts, runbooks, incident records and postmortems use it; no other document keeps its own. A notification platform is almost never "completely down": what matters is which message class stopped, how wide the damage is and whether it can be undone. Severity is therefore message class × breadth × reversibility, then adjusted with the modifiers.

## Levels

| Severity | What it looks like | Response |
|---|---|---|
| SEV1 | `security`, `transactional` or `action_required` messages cannot be sent on any channel or for any tenant; a message was accepted and then lost; a compliance breach (commercial message without consent, an İYS deadline missed); personal data leaked or content reached the wrong recipient; a provider account was suspended; users receive nothing while the SLO looks green | Page at once, night included; an incident commander is mandatory |
| SEV2 | `marketing` stopped; one channel does not work at all but a fallback does; a funnel gap crossed its threshold; a reputation metric is close to its limit; one large tenant is seriously affected | Page, outside working hours too, by the class threshold |
| SEV3 | One tenant affected with a working fallback; slow exhaustion (disk, quota); one webhook endpoint dead | Ticket, next working day |
| SEV4 | A missing signal, an outdated runbook, technical debt | Plan |

## Modifiers

Start from the level above, then apply every modifier that holds:

- Something irreversible happened (messages sent that cannot be recalled, tokens disabled, a bulk cancel): +1.
- Compliance or legal exposure: at least SEV1, whatever else holds.
- It is spreading (more tenants, channels or providers over time): +1.
- The `security` class is affected: +1.
- It happens during a known peak (campaign day, holiday, end of month): +1.
- A fallback works: −1.
- A single small tenant: −1.
- A provider incident where Relay has nothing to do does not lower the severity; it changes the escalation path (to the provider), not the urgency.

SEV1 is the ceiling and SEV4 the floor.

## Response targets

Each target is measured from the incident record's timestamps and reported in the postmortem (`postmortem.md`).

| Severity | Page acknowledged | Incident commander in place | First customer notification | Customer updates |
|---|---|---|---|---|
| SEV1 | ≤ 5 minutes | ≤ 15 minutes | ≤ 30 minutes | at least every 30 minutes |
| SEV2 | ≤ 15 minutes | when declared | ≤ 60 minutes when customers are affected | every 60 minutes |
| SEV3 | next working day | not needed | when the tenant is affected, through its account team | as agreed |
| SEV4 | planned | not needed | none | none |

## Examples

- One webhook endpoint of a tenant is dead: SEV3; it happens on the tenant's campaign day (known peak, +1): SEV2.
- A campaign went to an audience without consent: compliance exposure, at least SEV1; irreversible: stays SEV1 (ceiling).
- One-time codes by SMS late by 5 minutes for one small tenant: SEV1 (transactional cannot be sent in time) −1 (single small tenant) = SEV2.
