---
id: wake-up-test
kind: alert
severity: SEV4
channels: [none]
tenant_scope: none
alerts: [RelayWakeUpTest]
last_tested: 2026-11-18
tested_by: none
automation: 4
eta_minutes: 5
reversible: true
---

# Wake-up test

## Symptom

`RelayWakeUpTest` pages every Thursday at 09:00 UTC for ten minutes. It is a scheduled test of the path that wakes the on-call: Prometheus, Alertmanager, the webhook to the paging provider, the provider's escalation and the on-call's phone. Nothing in Relay is broken.

## Impact

None by itself. A test page that nobody acknowledges means real pages would not wake anyone either: every SEV1 response target depends on this path. Relay never pages through Relay; the path runs outside it on purpose.

## Diagnosis

Did the alert fire in Prometheus?

```sh
curl -fsS "$PROMETHEUS_URL/api/v1/query" --data-urlencode 'query=ALERTS{alertname="RelayWakeUpTest"}'
```

Did Alertmanager receive it and which receiver took it?

```sh
curl -fsS "$ALERTMANAGER_URL/api/v2/alerts?filter=alertname%3D%22RelayWakeUpTest%22" | jq '.[] | {status, receivers}'
```

Did the webhook to the paging provider succeed? Alertmanager counts failed notifications per receiver:

```sh
curl -fsS "$ALERTMANAGER_URL/metrics" | grep 'alertmanager_notifications_failed_total{.*integration="webhook"'
```

Then check the paging provider's own status page and its delivery log for the page: which channel it used (mobile push and voice call first; SMS is never the only path) and when the on-call acknowledged it.

## Decision tree

```text
test page sent
├── acknowledged within 5 minutes -> record it in the handoff log, done
├── not acknowledged
│   ├── alert not in Prometheus ALERTS -> rule group not loaded: check the
│   │   Prometheus rule files and its alertmanager target
│   ├── in Alertmanager, webhook failures > 0 -> receiver URL file or
│   │   provider endpoint broken: fix the secret or the provider integration
│   ├── provider received it, did not notify -> provider incident or the
│   │   on-call's contact rules: check provider status page, phone settings
│   └── notified, nobody woke -> the on-call's device path (do not disturb,
│       battery, signal): agree a second channel, re-run the test tonight
└── fired outside Thursday 09:00 UTC -> Prometheus clock wrong: fix NTP
```

## Mitigation

Acknowledge the page in the paging provider. Nothing in Relay needs to change. After a fix, re-run the path at once by sending a test alert straight to Alertmanager (it expires after five minutes):

```sh state-changing
amtool alert add RelayWakeUpTest severity=page decision=OP-78 --annotation=summary="manual wake-up test" --end="$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)" --alertmanager.url="$ALERTMANAGER_URL"
```

## Fix and escalation

Every on-call person verifies the path with a test at night before their first shift, and the weekly test keeps it verified. A failed test is fixed before the end of the day; until then the incident commander rota covers with a second, independent channel. Escalate a paging provider failure to the provider's support and watch its status page.
