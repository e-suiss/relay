# Relay runbooks

One Markdown file per alert or procedure. Every alert in `deploy/observability/alerts.yaml` points its `runbook_url` at one of these files, and `mix relay.lint.runbooks` (part of `mix lint`, run in CI) keeps the two in step. Incident response (severity, roles, notification, postmortem, on-call handoff, automation ladder, game days) lives in [`incident/`](incident/).

The runbooks do not depend on Relay being up: they are plain files in this repository, and every push to `main` and every release also builds them into one self-contained HTML file (the `runbooks` workflow artifact, and the `relay-runbooks-<version>.html` release asset). Keep a copy where you can open it when the cluster, the console and the status of Relay itself are unknown.

## Before you start

The commands are written to be pasted as they are once these variables are set in your shell:

| Variable | Example | Used for |
|---|---|---|
| `RELAY_EXEC` | `kubectl exec deploy/relay-all --` (Helm release `relay`, node group `all`) | Running `bin/relay rpc` and `bin/relay eval` inside a running Relay node |
| `MAINT_DATABASE_URL` | `postgres://relay_maint@db/relay` | Read-only diagnosis queries with `psql` |
| `DATABASE_URL` | `postgres://relay_app@db/relay` | The kill switch emergency procedure only |
| `PG_ADMIN_URL` | `postgres://postgres@db/relay` | Ending backends and other database administrator steps |
| `VALKEY_URL` | `redis://valkey:6379` | `valkey-cli -u "$VALKEY_URL"` |
| `PROMETHEUS_URL` | `http://prometheus:9090` | Instant queries: `curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=…'` |
| `ALERTMANAGER_URL` | `http://alertmanager:9093` | Alert state and the wake-up test |
| `RELAY_METRICS_URL` | `http://relay-node:9568/metrics` | One node's metrics |
| `RELAY_URL` | `https://relay.example.com` | `/readyz`, `/livez` and the operator API |
| `RELAY_OPERATOR` | `alice@example.com` | The operator named in release commands and their audit records |

## Format

```markdown
---
id: partition-horizon            # the file name without .md
kind: alert                      # alert | procedure | incident
severity: SEV2                   # SEV1 … SEV4, see incident/severity.md
channels: [all]                  # all, none or channel names
tenant_scope: all                # none | one | some | all
alerts: [RelayPartitionHorizon]  # alerts that point here; [] for a procedure
last_tested: 2026-11-18          # date of the last game day or incident that used it
tested_by: none                  # game_day | incident | none (never exercised yet)
automation: 1                    # 1 copy-paste, 2 one button, 3 alert-triggered with approval, 4 automatic
eta_minutes: 15                  # expected time to mitigate
reversible: true                 # whether the mitigation can be undone
---
```

An alert or procedure runbook has exactly these six sections, in this order, none of them empty (write "Unknown." when nothing is known yet):

1. `## Symptom` — what the alert or the operator sees.
2. `## Impact` — who is affected and how far it spreads.
3. `## Diagnosis` — copy-paste commands, each followed by what its output means.
4. `## Decision tree` — a plain text tree in a ` ```text ` block.
5. `## Mitigation` — stop the bleeding first, restore the service, keep the evidence.
6. `## Fix and escalation` — the permanent fix and who to call.

A command block that changes state is fenced as ` ```sh state-changing ` and holds exactly one command; read-only blocks use ` ```sh `. Every mitigation is an operator API call, a CLI command or a release command, so it is audited and safe to run twice.

`last_tested` moves only when a game day or a real incident used the runbook. A runbook whose last test is older than 183 days fails CI; a new runbook starts with `tested_by: none` and the date it was written and goes through a game day within 90 days (see `incident/game-days.md`).

## Checking

```sh
mix relay.lint.runbooks
```

It fails on a missing or empty section, a missing or invalid front matter field, a `last_tested` older than 183 days, an alert without a `runbook_url` or whose file does not exist, an alert runbook no alert points to, and a state-changing block with more than one command.
