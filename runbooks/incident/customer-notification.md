---
id: customer-notification
kind: incident
last_tested: 2026-11-18
tested_by: none
---

# Customer notification

## Never through Relay

Relay does not notify about its own incidents. Customer notification goes through:

1. The status page (primary): static, hosted separately from every Relay region; its template and publish script are in `ops/status-page/`.
2. A separate operations e-mail account with its own sending reputation (secondary), never the provider accounts Relay sends with.

A banner in the console is not a reliable path: the console may be the thing that is down.

## Timing

First notification and update rhythm per severity are in `severity.md`. The first notification goes out on time even when little is known; "we are investigating" with the affected classes is better than silence.

## Content

Write what happened, not what might have happened:

- What is affected, by message class (`security`, `transactional`, `action_required`, `marketing`) and channel.
- Since when (UTC), and whether it is ongoing.
- What was irreversible, stated plainly (for example: "about 12 000 marketing e-mails were sent to the wrong audience between 10:02 and 10:09 UTC").
- What customers should do, if anything (retry with the same idempotency keys, nothing to do, contact support).
- When the next update comes.

## Template

```text
[Investigating | Identified | Monitoring | Resolved] <UTC time>
Affected: <classes> on <channels>, <regions>, since <UTC time>.
Impact: <what customers and their recipients see>.
Irreversible: <none | what was sent, cancelled or disabled, with numbers>.
What to do: <nothing | retry | contact>.
Next update: <UTC time>.
```
