---
id: roles
kind: incident
last_tested: 2026-11-18
tested_by: none
---

# Incident roles

## Incident commander

Owns the incident: sets the severity, decides, delegates, keeps the timeline and calls the next update. The commander does not fix things; a commander who starts typing commands hands the role over first. Mandatory for every SEV1, in place within 15 minutes.

## Operations lead

Runs the runbook: diagnosis, mitigation, every command. Says each state-changing command in the channel before running it and its result after. One operations lead at a time; helpers work through them.

## Communications lead

Owns every message to customers and to the rest of the company: the status page, the separate operations e-mail account, the tenant account teams. Never sends through Relay (`customer-notification.md`). Keeps the update rhythm of the severity.

## Compliance lead

Joins whenever the compliance modifier holds: messages without consent, an İYS deadline, quiet hours, personal data sent to the wrong person. Decides whether a personal data breach assessment starts and whether legal approval is needed before reopening.

## Handing a role over

A role changes hands in the incident channel, never silently:

1. The outgoing person writes: current state, what is engaged (read the kill switches live), what is running, the next planned step and the next update time.
2. The incoming person reads it back and writes "I have the <role>".
3. The commander records the UTC time of the handover in the timeline.

Hand over before exhaustion: plan a handover after four hours in a role.
