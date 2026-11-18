---
id: iys-reconciliation-drift
kind: alert
severity: SEV3
channels: [sms, voice, email]
tenant_scope: some
alerts: [RelayIysReconciliationDrift]
last_tested: 2026-11-18
tested_by: none
automation: 4
eta_minutes: 120
reversible: true
---

# İYS reconciliation drift

## Symptom

`RelayIysReconciliationDrift` fires: for two hours the hourly İYS reconciliation keeps finding drift (`relay_iys_reconciliation_drift > 0`): confirmed uploads the local copy does not hold, or permissions in the copy that no pull reported.

## Impact

The local copy disagrees with İYS for some addresses of some brands. The read path verifies drifted permissions against İYS on its own, a bounded number per run, so a small drift heals by itself. Drift that stays means the copy may answer wrongly for those addresses: either holding marketing that is allowed, or, worse, allowing marketing İYS no longer holds.

## Diagnosis

Drift per brand and when it was last reconciled:

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT s.tenant_id, s.environment, b.brand_code, s.drift_count, s.reconciled_at, s.last_pull_at, s.stale_state FROM relay.iys_sync_states s JOIN relay.iys_brands b ON b.tenant_id = s.tenant_id AND b.environment = s.environment AND b.id = s.brand_id WHERE s.drift_count > 0 ORDER BY s.drift_count DESC"
```

A `drift_count` that falls run after run is the read path healing. One that stays or grows does not heal.

Failed and stuck uploads of the same brands (replace the tenant):

```sh
psql "$MAINT_DATABASE_URL" -c "SELECT state, error_code, count(*), min(created_at) FROM relay.iys_uploads WHERE tenant_id = '00000000-0000-0000-0000-000000000000' AND created_at > now() - interval '7 days' GROUP BY 1, 2 ORDER BY 3 DESC"
```

Many `failed` uploads with one `error_code` explain drift of the "confirmed upload not in the copy" kind. The tenant sees the same list with `GET /v1/iys/uploads?state=failed`.

## Decision tree

```text
RelayIysReconciliationDrift
├── drift_count falling between runs
│   └── self-healing: watch, no action
├── drift_count steady or growing
│   ├── failed uploads with one error_code
│   │   └── fix the upload cause; the operator retries failed uploads in the console
│   └── no failed uploads
│       └── İYS's pull does not report the service provider's movements:
│           raise it with İYS (Fix)
└── copy also stale (stale_state <> fresh)
    └── follow iys-copy-stale.md first
```

## Mitigation

The verification runs automatically and is bounded; nothing to start by hand. A failed upload is retried by the operator in the console (`POST /v1/operator/iys/uploads/{upload_id}/retry`, audited as `iys_upload.retried`) once its cause is fixed. If drift may be allowing marketing to refused addresses, stop the brand's marketing with a tenant kill switch for `marketing` as in `iys-copy-stale.md` until the drift is gone.

## Fix and escalation

Drift that stays means İYS's pull does not report the service provider's movements for those addresses; raise it with İYS with the brand code and the times of the drifted uploads. Upload failures caused by Relay go to the compliance integration owners.
