---
id: game-days
kind: incident
last_tested: 2026-11-18
tested_by: none
---

# Game days

## Rhythm

| What | How often | Where |
|---|---|---|
| Game day | Once a month | Every region |
| Scenario families (A provider, B compliance, C infrastructure, D people and procedure) | Rotating; every family at least once a quarter | Every region |
| Kill switch propagation drill | Once a month | Every region |
| New runbook through a game day | Within 90 days of being written | The region it was written for |
| Wake-up path test | Once a week, per on-call person (`../wake-up-test.md`) | Every paging path |
| Fault injection limits | TTL at most one hour, rate at most 100 %, only in the `test` environment or an installation started in chaos mode | |

A runbook used in a game day or a real incident gets `last_tested` set to that date and `tested_by: game_day` or `tested_by: incident`. A runbook older than 183 days fails CI, so the rhythm above keeps every runbook inside the limit.

## Calendar

Quarter template, one line per month and region. Copy it into the operations calendar each quarter; the families rotate so that each appears in the quarter.

| Month | Family | Scenario | Runbooks exercised | Kill switch drill |
|---|---|---|---|---|
| 1 | A provider | Provider returns `429` and exhausts concurrent streams | `../provider-breaker-open.md`, `../capacity-incident.md` | yes |
| 1 | D people | Diagnose without the runbook, then with it; role handover mid-incident | any one alert runbook, `roles.md` | |
| 2 | C infrastructure | PostgreSQL failover under send load: zero loss | `../postgres-failover.md`, `../funnel-data-loss.md` | yes |
| 2 | B compliance | İYS pull stops; template without its legal footer | `../iys-copy-stale.md` | |
| 3 | C infrastructure | Valkey restart: polling and the fallback limiter | `../valkey-loss.md`, `../queue-polling.md` | yes |
| 3 | D people | Mass mis-send drill: stop under 60 s, staged reopen | `../mass-mis-send.md`, `../kill-switch-emergency.md`, `customer-notification.md` | |

Other scenarios by family:

- A: provider credential failure, bounce rate spike, template paused by the provider, delayed delivery reports.
- B: compliance lint removed from a template, consent import missing.
- C: dispatcher process killed (zero duplicates), database pool saturation (acceptance answers `503`, nothing accepted and not queued).
- D: independent customer notification path (status page and operations e-mail), wake-up test at night.

## Scenario template

Every scenario states a hypothesis, what is measured and the acceptance criterion before it starts. The measured outcome is a time.

```markdown
# Game day <date>, <region>, family <A|B|C|D>: <scenario>

## Hypothesis
When <fault>, Relay <expected behaviour> and the on-call <expected response>.

## Setup
- Environment: test | chaos mode installation
- Fault: <kind>, scope <installation|tenant|channel|provider>, rate <%>, TTL <≤ 1 h>
- Runbooks under test: <ids>
- Observers: <names>; incident commander for the exercise: <name>

## Measurements (UTC)
| Measure | Target | Result |
|---|---|---|
| Fault start to alert | | |
| Alert to acknowledgement | ≤ 5 min (SEV1) | |
| Acknowledgement to mitigation | runbook eta_minutes | |
| Kill switch engaged to every node | < 2 s | |
| Mass mis-send decision to last job paused | < 60 s | |
| Messages lost / duplicated | 0 | |

## Acceptance
- [ ] Every target met, or an action item opened for each miss
- [ ] Runbooks used: `last_tested` and `tested_by: game_day` updated in the same pull request
- [ ] Runbook gaps found: <list>, fixed in the same pull request or ticketed

## Action items
| Action | Owner | Due |
|---|---|---|
```
