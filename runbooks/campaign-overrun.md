---
id: campaign-overrun
kind: alert
severity: SEV3
channels: [all]
tenant_scope: one
alerts: [RelayCampaignOverrun]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# Campaign overrun

## Symptom

`RelayCampaignOverrun` fires: a campaign on a lane has been running longer than 1.5 times its estimated duration. The campaign engine reports it once per campaign (`relay_campaign_overrun_total{lane}`) and marks the campaign `overrun_reported`.

## Impact

The campaign still sends, only later than the tenant planned. Late marketing can collide with the recipients' quiet hours (it is deferred, not lost) or with the campaign's deadline, after which its open stages are cancelled and the members left are counted `expired`. The lane's backlog may also delay other tenants' messages of the same class.

## Diagnosis

Running campaigns that reported an overrun, with their progress:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, environment, id, message_class, state, triggered_at, estimated_duration_s, now() - triggered_at AS running_for, deadline, audience_count, reachable_count FROM relay.campaigns WHERE overrun_reported AND state IN ('running', 'paused') ORDER BY triggered_at"
```

A campaign `paused` is waiting for something: its `pause_rule_id` says what (a kill switch, `campaign.ramp_alarm`, a changed workflow, an exhausted quota).

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT id, pause_rule_id FROM relay.campaigns WHERE overrun_reported AND state = 'paused'"
```

The oldest job age of the campaign's lane (a slow lane slows every campaign on it):

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=max by (lane) (relay_queue_oldest_job_age_seconds)' | jq -r '.data.result[] | "\(.metric.lane) \(.value[1])"'
```

Whether a provider breaker is open or a rate limit holds the channel: see `provider-breaker-open.md` and `queue-oldest-job.md`.

## Decision tree

```text
RelayCampaignOverrun
├── campaign paused
│   ├── pause_rule_id is a kill switch rule
│   │   └── intended stop; the tenant's estimate no longer applies: tell the tenant
│   └── ramp alarm, workflow change or quota
│       └── waits for the tenant administrator: tell the tenant
├── running, lane oldest job age high
│   └── capacity: follow capacity-incident.md (provider → queue → nodes → DB)
└── running, lane healthy
    └── the provider or the tenant's rate limit is slower than estimated:
        tell the tenant, adjust the estimate or the rate
```

## Mitigation

Usually nothing to stop. If the tenant asks to stop the campaign, it does so itself with `relay kill-switch engage --scope campaign --ref cmp_REPLACE` or the console; a campaign that must not continue past a time is cancelled by the tenant through `POST /v1/campaigns/{campaign_id}/cancel`. A paused campaign is resumed by a tenant administrator in the console (`POST /v1/operator/campaigns/{campaign_id}/resume`), never by the on-call operator on the tenant's behalf.

## Fix and escalation

Tell the tenant's account team which campaign overran and why. If the lane is the bottleneck for many tenants, handle it as a capacity incident. If estimates are wrong across campaigns, open an issue for the campaign planner with the measured durations.
