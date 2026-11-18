---
id: postmortem
kind: incident
last_tested: 2026-11-18
tested_by: none
---

# Postmortem

## When it is required

A blameless postmortem is required for every SEV1, every SEV2 that lasted longer than two hours, a SEV3 that happened again, every incident where something irreversible happened, and every incident in which a kill switch was engaged. It is complete only when every action item is closed.

## Template

Copy this block into the postmortem document.

```markdown
# Postmortem: <title> (<SEV>, <date>)

## Impact, in numbers
- Not sent, by class: security <n>, transactional <n>, action_required <n>, marketing <n>
- Sent wrongly (wrong audience, content or recipient): <n>
- Tenants affected: <n>; recipients affected: <n>
- Consents lost or misapplied: <n>
- Provider reputation: <complaint/bounce rates, warnings, suspensions>
- Irreversible: <what and how many>

## Response targets (from the incident record, see incident/severity.md)
| Target | Goal | Measured |
|---|---|---|
| Page acknowledged | | |
| Incident commander in place | | |
| First customer notification | | |
| Update rhythm kept | | |
| Kill switch held (if used) | < 60 s for a mass mis-send | |

## Timeline (UTC)
| Time | Event |
|---|---|
| | Started |
| | Detected (by what) |
| | Declared |
| | Mitigated |
| | Resolved |

## Detection
- Time to detect: <minutes>
- Which alert fired, or why none did

## Causes
- <technical and organisational causes; no names>

## What went well / what went badly / where we got lucky

## Action items
| Kind (prevent / detect / mitigate) | Action | Owner | Due |
|---|---|---|---|

## Runbook impact
- Runbooks used: <ids>; what was wrong or missing in them
- `last_tested` updated for: <ids> (tested_by: incident)
```
