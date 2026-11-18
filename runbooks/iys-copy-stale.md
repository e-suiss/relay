---
id: iys-copy-stale
kind: alert
severity: SEV2
channels: [sms, voice, email]
tenant_scope: some
alerts: [RelayIysCopyStale, RelayIysCopyStopped]
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 30
reversible: true
---

# İYS copy stale or stopped

## Symptom

`RelayIysCopyStale` fires when a brand's local copy of İYS has not completed a pull for six hours (`relay_iys_copy_warning_brands > 0`); the tenant was told with `iys.copy_stale` and marketing still sends from the copy. `RelayIysCopyStopped` pages when the copy is a day old (`relay_iys_copy_stopped_brands > 0`): the brand's marketing on SMS, voice and e-mail is skipped with `iys.stale` until a pull completes. Both gauges come from `Relay.Iys.SyncSweep`, which runs every five minutes on the `maintenance` queue.

## Impact

While the copy is stale, a rejection a recipient made at İYS after the last pull is not known to Relay, so marketing could reach a person who refused: that would be a compliance breach. When the copy stops, Relay holds the brand's marketing instead, which protects recipients and stops the tenant's campaigns. Refusals made in Relay are still applied at once and their İYS writes wait in the upload queue.

## Diagnosis

Brands whose copy is past the warning or the stop age, with their last pull and error:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT s.tenant_id, s.environment, b.brand_code, s.stale_state, s.last_pull_at, s.last_attempt_at, s.last_error_code, s.last_error_at, s.full_sync_started_at FROM relay.iys_sync_states s JOIN relay.iys_brands b ON b.tenant_id = s.tenant_id AND b.environment = s.environment AND b.id = s.brand_id WHERE s.stale_state <> 'fresh' ORDER BY s.last_pull_at NULLS FIRST"
```

What `last_error_code` means: `cursor_rejected` (İYS no longer accepts the cursor; the next run starts a full synchronisation by itself), `http_401` or `http_403` (credential or the integrator's authorisation for the brand), `http_429` (İYS rate limit), `http_5xx` or `unavailable` (İYS or the network). A `last_attempt_at` that is not moving means the jobs do not run at all.

Pull results across the installation:

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=sum by (result) (increase(relay_iys_pull_total[1h]))' | jq -r '.data.result[] | "\(.metric.result) \(.value[1])"'
```

Whether the sweep and the read path jobs run (job table, read with the administrator role):

```sh
psql "$PG_ADMIN_URL" -c "SELECT worker, state, count(*), max(attempted_at) FROM relay_queue.oban_jobs WHERE worker IN ('Relay.Iys.SyncSweep', 'Relay.Iys.SyncWorker') AND inserted_at > now() - interval '1 day' GROUP BY 1, 2 ORDER BY 1, 2"
```

The same state per brand is in the console (İYS synchronisation page, `GET /v1/operator/iys/sync`).

## Decision tree

```text
RelayIysCopyStale / RelayIysCopyStopped
├── last_attempt_at not moving
│   └── jobs do not run: check the maintenance queue and worker nodes
│       (queue-oldest-job.md, singleton-leaderless.md)
├── last_error_code http_401 / http_403
│   └── credential or integrator authorisation: the tenant fixes it in its İYS config
├── last_error_code http_429
│   └── İYS rate limit: wait; check no other installation shares the credential
├── last_error_code http_5xx / unavailable
│   └── İYS or network down: check İYS status, the egress path; wait and keep the hold
└── cursor_rejected
    └── a full synchronisation starts by itself; watch full_sync_started_at
```

At any point: if a marketing send reached an address refused at İYS, declare a SEV1 compliance incident.

## Mitigation

Keep the hold: Relay already skips the brand's marketing once the copy is stopped, and that is the safe state. Do not mark the copy fresh by hand and do not release marketing before a pull completes. If the tenant must stop marketing earlier, during the warning period, it engages a kill switch itself; the on-call operator can do it with a tenant kill switch for `marketing`:

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"iys copy stale\", ttl: \"1d\", scope: :tenant, tenant: \"ten_REPLACE\", environment: :live, message_class: \"marketing\"))"
```

## Fix and escalation

Fix what the error code names: the tenant renews its İYS credential or the integrator's authorisation; network and egress issues go to the platform owners. The next sweep pulls again by itself; nothing has to be replayed. After a gap longer than seven days the brand runs a full synchronisation and approvals held before the gap count again only once verified against İYS, which İYS's hourly status limit paces. Escalate to the compliance lead when the copy stays stopped for more than a business day.
