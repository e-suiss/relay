---
id: region-acceptance
kind: procedure
severity: SEV3
channels: [all]
tenant_scope: none
alerts: []
last_tested: 2026-11-18
tested_by: none
automation: 1
eta_minutes: 120
reversible: true
---

# Region acceptance

## Symptom

A new region installation (`tr`, `eu` or `us`) is deployed and must be accepted before the first tenant is provisioned in it, or an existing region was rebuilt after a disaster and must be accepted again before it takes traffic.

## Impact

None while the region has no tenants. A region opened without acceptance can put a tenant's personal data in the wrong country, page nobody when it breaks, or lack a working kill switch; each of those is SEV1 once a tenant is in it. A tenant's region never changes, so a mistake is not fixed by moving the tenant later.

## Diagnosis

The `region-acceptance` workflow (GitHub Actions, run by hand with the region's base URL and the drill credentials as secrets) runs the isolation, shadow send, failover, archive restore and kill switch drills against the region and keeps their times in its `acceptance-report.json` artifact; attach that report to the acceptance record.

Every check below is read-only. Run them against the new region's own endpoints and databases.

The installation's region, as stored and as published:

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Datasets.installation_region())'
```

```sh
curl -fsS "$RELAY_URL/.well-known/relay-configuration" | jq '{region, api_base}'
```

Both must name the region you are opening, and `api_base` must be this region's own host.

Dependencies of every node:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' "$RELAY_URL/readyz"
```

```sh
$RELAY_EXEC bin/relay rpc 'IO.inspect(Relay.Platform.health())'
```

Where the data lives (database, replicas, backups and the audit object store must all be in the region):

```sh
psql "$MAINT_DATABASE_URL" -Atc "SELECT inet_server_addr(), current_setting('data_directory', true)"
```

The kill switch path works end to end: engage and release a short test kill switch on a test tenant (Mitigation), and read `relay_kill_switch_effect_seconds`.

Paging reaches a human: fire the wake-up test (`wake-up-test.md`) for this region's Alertmanager.

## Decision tree

```text
new region deployed
├── installation_region or discovery region wrong -> stop; fix the install
├── /readyz not 200 on every node -> fix dependencies first
├── any data store outside the region -> stop; move it before any tenant
├── kill switch test failed or took > 2 s to reach every node -> stop
├── wake-up test not acknowledged by the on-call -> fix paging first
├── status page and runbook offline copy not reachable without this region
│   └── fix (they must not depend on Relay)
└── all checks pass -> record the acceptance; tenants may be provisioned
```

## Mitigation

The kill switch test, on a test tenant in its `test` environment (five minutes, then it expires by itself):

```sh state-changing
$RELAY_EXEC bin/relay rpc "IO.inspect(Relay.Release.KillSwitch.engage(operator: \"$RELAY_OPERATOR\", reason: \"region acceptance test\", ttl: \"5m\", scope: :tenant, tenant: \"ten_REPLACE\", environment: :test))"
```

Nothing else in this procedure changes state: a failed check is fixed in the deployment, then the whole list is run again.

## Fix and escalation

Record the acceptance (date, region, who ran it, each check's result and the measured kill switch time) in the operations log; the region is open only with that record. Escalate a residency failure (any store outside the region) to the security and compliance lead before anything else.
