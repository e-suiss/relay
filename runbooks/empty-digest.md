---
id: empty-digest
kind: alert
severity: SEV3
channels: [all]
tenant_scope: some
alerts: [RelayEmptyDigest]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 60
reversible: true
---

# Empty digest

## Symptom

`RelayEmptyDigest` fires: more than 20% of the digest flushes of the last six hours were empty (`relay_digest_flush_total{result="empty"}`). A digest window reached its fire time with no item left to send, so it closed `empty` instead of `fired`.

## Impact

No message is lost: an empty window sends nothing because there is nothing to send. The cost is wasted work and, more often, a digest definition that does not match its events (a filter that drops every item, a window that opens for events that are later cancelled or read). Recipients may be missing digests they expect.

## Diagnosis

The share of empty flushes now:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (result) (increase(relay_digest_flush_total[6h]))' | jq -r '.data.result[] | "\(.metric.result) \(.value[1])"'
```

Which tenants and window origins produce the empty windows:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT tenant_id, environment, origin, window_mode, count(*) FILTER (WHERE state = 'empty') AS empty, count(*) FILTER (WHERE state = 'fired') AS fired FROM relay.digest_windows WHERE updated_at > now() - interval '6 hours' GROUP BY 1, 2, 3, 4 ORDER BY empty DESC LIMIT 20"
```

`origin` tells where the windows come from: `step` is a workflow digest step, `density` a category density hold, `quiet_hours` a quiet hours hold. One tenant with `step` dominating points to its workflow definition. `quiet_hours` or `density` across many tenants points to Relay.

How empty windows closed (replace the tenant):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT close_reason, cumulative_count, count(*) FROM relay.digest_windows WHERE tenant_id = '00000000-0000-0000-0000-000000000000' AND state = 'empty' AND updated_at > now() - interval '6 hours' GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20"
```

A `cumulative_count` above zero with an empty close means items entered and left the window before it fired (cancelled, read or expired items).

## Decision tree

```text
RelayEmptyDigest
├── one tenant, origin = step
│   ├── items entered and left (cumulative_count > 0)
│   │   └── its events are cancelled or read before the window fires: tell the tenant
│   └── nothing ever entered
│       └── the step's filter or key matches no event: tell the tenant
├── origin = quiet_hours or density, many tenants
│   └── Relay side: escalate to the workflow owners
└── started right after a deploy
    └── treat as a regression: escalate, consider rollback
```

## Mitigation

Nothing has to be stopped; an empty window sends nothing. Do not edit a tenant's workflow on its behalf. If a Relay deploy caused it, roll the deploy back through the normal release process.

## Fix and escalation

The tenant fixes its digest step (key, filter, window length) and publishes a new workflow version. A Relay regression goes to the workflow owners with the origin, the window mode and the first hour the share rose. Unknown otherwise.
