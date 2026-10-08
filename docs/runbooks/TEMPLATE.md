# Runbook: <alert name>

One file per alert (T-63, T-66). Copy this template to `docs/runbooks/<alert-name>.md`.

## Meaning
What the alert indicates, in one or two sentences. Link the signal in the specification (§14, §20).

## Impact
Who or what is affected: which message classes, tenants, channels or regions, and whether OTP/security delivery or compliance gates are at risk.

## Diagnosis
1. Dashboards and queries to check first (delivery funnel from the ledger, provider circuit state, queue lanes).
2. How to tell the likely causes apart.

## Remediation
Step-by-step actions. Never use a path that bypasses a compliance or security gate; use the kill switch for emergency stops. Paging and customer notifications for a Relay incident never go through Relay itself.

## Escalation
Who to notify and when, including security incident and coordinated disclosure triggers.
