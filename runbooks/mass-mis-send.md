---
id: mass-mis-send
kind: procedure
severity: SEV1
channels: [all]
tenant_scope: some
alerts: []
last_tested: 2026-11-18
tested_by: none
automation: 2
eta_minutes: 1
reversible: false
---

# Mass mis-send: stop first, think later

## Symptom

Messages are going out that should not: the wrong audience, the wrong template or content, another person's data in a message, a campaign started twice, marketing without consent. It is reported by a tenant, by recipients, by a skip or duplicate alert, or seen in the console.

## Impact

Every message already handed to a provider is out and cannot be recalled. Every minute before the stop adds recipients. Another person's data in a message is a personal data breach. Marketing without consent is a compliance breach. Both are SEV1 by themselves (`incident/severity.md`).

## Diagnosis

Do not diagnose before the stop. Mitigation step 1 comes first; the target is under 60 seconds from the decision to the last queued job paused. Diagnose only enough to pick the narrowest scope that certainly covers the harm: a campaign, a workflow, a sender, a tenant, or the platform when in doubt.

What is in force already:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Release.KillSwitch.list())'
```

After the stop, how far it went (deliveries of the last hour per tenant and channel, handed off and paused):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, channel, count(*) FILTER (WHERE accepted_at IS NOT NULL) AS handed_off, count(*) FILTER (WHERE paused_at IS NOT NULL AND failure_kind IS NULL) AS paused, count(*) AS total FROM relay.deliveries WHERE created_at > now() - interval '1 hour' GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 30"
```

How long the stop took, as measured by Relay (from the stop to the last queued job paused):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (platform) (relay_kill_switch_effect_seconds)'
```

## Decision tree

```text
wrong messages are going out
├── 1. STOP: engage a kill switch on the narrowest certain scope (do not wait)
│   └── unsure of the scope? -> platform scope, narrow it later
├── 2. hold: the kill switch pauses queued deliveries; check paused counts
├── 3. classify
│   ├── another person's data in a message -> personal data breach:
│   │   compliance lead starts the breach assessment now
│   ├── marketing without consent or an İYS breach -> compliance lead
│   └── otherwise -> tenant decides with the account team
├── 4. paused deliveries
│   ├── content wrong -> cancel them (Mitigation 3); never resume
│   └── content right, only the pace was wrong -> keep them paused until reopen
└── 5. reopen only through the checklist (Mitigation 4); never automatically
```

## Mitigation

1. Stop. Campaign scope through the CLI with the tenant's API client (allowed for campaign and workflow scopes):

```sh state-changing
relay kill-switch engage --scope campaign --ref cmp_REPLACE --reason "mass mis-send" --ttl PT2H
```

Any other scope from a running node (tenant scope shown; `scope: :platform` stops everything). If neither works, follow `kill-switch-emergency.md`:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"mass mis-send\", ttl: \"2h\", scope: :tenant, tenant: \"ten_REPLACE\", environment: :live))"
```

2. Confirm it holds: the record is in force and the paused count grows, then stops growing:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum(increase(relay_kill_switch_paused_total[10m]))'
```

3. If the paused deliveries carry the wrong content, cancel them (each gets `cancelled` with a rule id; this cannot be undone):

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.bulk_cancel(\"ksw_REPLACE\", operator: \"$RELAY_OPERATOR\", reason: \"mass mis-send: wrong content\"))"
```

Never send an automatic "sorry" message to the same audience. Any follow-up message is the tenant's decision, made like a new campaign.

4. Reopen is a management decision. Go through the checklist, then open in stages, each stage watched for at least 15 minutes:

- [ ] Root cause fixed and the fix deployed.
- [ ] The fix verified in the `test` environment with the same template and audience shape.
- [ ] People who already received the message will not receive it again (dedup keys, audience exclusion or cancelled deliveries checked).
- [ ] Legal or compliance approval recorded when personal data or consent was involved.
- [ ] Approval reference written down (it goes into `confirm_relax:`).
- [ ] Stage 1 %, stage 10 %, stage 100 %.

Stage 1 % (a canary of the same kill switch; 10 % next with `{:canary, 10}`):

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.replace(\"ksw_REPLACE\", operator: \"$RELAY_OPERATOR\", reason: \"staged reopen 1%\", state: {:canary, 1}, ttl: \"2h\", confirm_relax: \"APPROVAL-REF\"))"
```

Stage 100 % releases the kill switch (paused deliveries stay paused; resume them with `Relay.Release.KillSwitch.resume/2` only if their content is right):

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.release(\"ksw_REPLACE\", operator: \"$RELAY_OPERATOR\", reason: \"reopen complete\", confirm_relax: \"APPROVAL-REF\"))"
```

## Fix and escalation

Declare the incident at once (`incident/declaration.md`); a mass mis-send is at least SEV1 when anything irreversible went out, and a postmortem is mandatory because a kill switch was engaged. Page the compliance lead for personal data or consent cases. Campaign safeguards that should have caught it (sample render approval, audience size approval, a small starting percentage) are action items of the postmortem.
