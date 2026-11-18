---
id: automation-ladder
kind: incident
last_tested: 2026-11-18
tested_by: none
---

# Automation ladder

## Levels

Every mitigation is an operator API call, a CLI command or a release command: testable, audited, and safe when a stressed operator runs it twice.

| Level | Meaning |
|---|---|
| 0 | Free text ("restart the thing"). Not accepted in a runbook. |
| 1 | Copy-paste command. |
| 2 | One button: a console action or one operator API / CLI call. The target for every mitigation. |
| 3 | Triggered by an alert, run after a human approves. |
| 4 | Fully automatic, people are told afterwards. |

An action moves up only when its decision rests on machine-observable signals alone, the action is reversible and bounded, and it fires at least twice a month. Irreversible actions (sending, disabling tokens, bulk cancel), decisions that need compliance context and provider reputation never open automatically: stopping may be automatic, reopening never is. Dead token cleanup never runs without an upper bound.

## Catalog

| Action | How | Level | Idempotency | Audit evidence |
|---|---|---|---|---|
| Engage a kill switch | Console; `POST /v1/operator/kill_switches`; `relay kill-switch engage` (campaign and workflow scopes); `Relay.Release.KillSwitch.engage/1`; database procedure (`../kill-switch-emergency.md`) | 2 | API: `Idempotency-Key` required; release and CLI: a second call writes a second record of the same stop, harmless; database procedure: the same id answers `exists` | `killswitch.engaged` |
| Tighten or stage a kill switch (canary, paused until) | Console; `POST /v1/operator/kill_switches/{id}/replace`; `Relay.Release.KillSwitch.replace/2` | 2 | API: `Idempotency-Key` required; only a record in force can be replaced | `killswitch.canary`, `killswitch.paused_until`, `killswitch.off` |
| Release a kill switch | Console; `POST /v1/operator/kill_switches/{id}/release`; `Relay.Release.KillSwitch.release/2` (needs `confirm_relax:`) | 2, never higher | API: `Idempotency-Key` required; only a record in force can be released | `killswitch.released` |
| Resume paused deliveries | `POST /v1/kill_switches/{id}/resume`; `Relay.Release.KillSwitch.resume/2` | 2, never higher | `Idempotency-Key` required; only paused deliveries are resumed | `killswitch.resume` |
| Cancel paused deliveries | `POST /v1/kill_switches/{id}/cancel_paused`; `Relay.Release.KillSwitch.bulk_cancel/2` | 2, never higher (irreversible) | `Idempotency-Key` required; only paused deliveries are cancelled, a cancelled delivery is terminal | `killswitch.bulk_cancelled`, `delivery.cancelled` |
| Dead-man pause of a tenant, campaign or workflow | Automatic | 4 for the stop; the reopen is level 2 | One active dead-man record per scope (`dead_man_active`) | `killswitch.auto_paused` |
| Load shedding of a lane | Automatic (`load_shed_controller`) | 4 | One transition per lane and phase, under the controller's fencing token | `relay.load_shed_events`; `l0` engaged is logged as an error |
| Provider breaker open and half-open | Automatic | 4 | Breaker state per provider | `relay_breaker_open` |
| Close an e-mail reputation circuit | `POST /v1/operator/email_reputation/{domain}/close` | 2, never higher | `Idempotency-Key` required | `email_reputation.closed` |
| Suspend or resume a tenant | `POST /v1/operator/tenants/{id}/suspend`, `/resume` | 2 | `Idempotency-Key` required | `tenant.suspended`, `tenant.resumed` |
| Suspend or resume a sender identity | `POST /v1/operator/sender_identities/{id}/suspend`, `/resume` | 2 | `Idempotency-Key` required | `sender_identity.suspended`, `sender_identity.resumed` |
| Suspend or resume a subscriber | `POST /v1/operator/subscribers/{id}/suspend`, `/resume` | 2 | `Idempotency-Key` required | `subscriber.suspended`, `subscriber.resumed` |
| Lift a suppression | `POST /v1/operator/suppressions/{id}/lift` | 2, never higher (compliance context) | `Idempotency-Key` required | `suppression.lifted` |
| Apply or lift a takedown | `POST /v1/operator/takedowns`, `/{id}/lift` | 2 | `Idempotency-Key` required | `takedown.applied`, `takedown.lifted` |
| Archive a provider account or rotate its credential | `POST /v1/operator/provider_accounts/{id}/archive`, `/rotate_credential` | 2 | `Idempotency-Key` required | `provider_account.archived`, `provider_account.credential_rotated` |
| Approve a campaign audience or resume a campaign | `POST /v1/operator/campaigns/{id}/approve_audience`, `/resume` | 2, never higher | `Idempotency-Key` required | `campaign.audience_approved`, `campaign.resumed` |
| Cancel a campaign | `POST /v1/campaigns/{id}/cancel` | 2, never higher (irreversible) | `Idempotency-Key` required | `campaign.cancelled` |
| Decide on held agent notifications | `POST /v1/agents/{id}/ceiling_decisions` (step-up) | 2 | `Idempotency-Key` required | `agent.ceiling_decided` |
| Retry a failed İYS upload | `POST /v1/operator/iys/uploads/{id}/retry` | 2 | `Idempotency-Key` required | Upload record state |
| Request Access pairing | `bin/relay rpc 'Relay.Access.Pairing.request(:all)'` | 1 | Pairs only environments not yet paired | Pairing logs |
| Rotate the subscriber token key | `Relay.Release.SubscriberTokenKey.rotate/1` | 1 | Check `Relay.Release.SubscriberTokenKey.status()` before a second run | Key table activation time |
| Dead token cleanup (soft disable) | Automatic device sweep, refuses to run without an upper bound | 4, bounded | Disabled devices stay disabled | Device state and sweep counts |
| Dead letter replay after a breaker closes | Automatic | 4 | Unknown. | Delivery ledger |
| Add or remove nodes | `kubectl scale` | 1 | Declarative replica count | Cluster audit log (outside Relay) |
| Promote a PostgreSQL replica | `../postgres-failover.md` | 1 | A promoted primary ignores a second promote | Database log (outside Relay) |
