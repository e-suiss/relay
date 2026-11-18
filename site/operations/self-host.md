# Self-host operations

A self-hosted installation runs the same release as the hosted service. The official compose file starts Access, PostgreSQL, Valkey and Relay with one command and has a single-node profile for small installations; for production, use the Helm chart on Kubernetes. Provider settings come from files or environment variables, and secrets are always passed by reference, never inline.

Channels that need no account work out of the box: plain SMTP, web push with VAPID, and the in-app inbox with realtime updates. Every other channel uses your own provider account. There is no way to send iOS push notifications without an Apple Push Notification service (APNs) account.

This page is the operating manual for that installation.

## Backup and restore

**PostgreSQL** is the only store you must back up. Take base backups and archive WAL continuously to an object store in the same region, with a WAL flush at least once a minute, so you can restore to any point in time. Restore into a fresh cluster, never over the running one, and rehearse a restore regularly: a backup you have not restored is a hope, not a backup. See [PostgreSQL HA and recovery](./postgres) for high availability and the recovery targets.

**Valkey** needs no backup. Losing it loses no data.

**Keys** live in your HSM. Back them up with your HSM vendor's procedure, keep the backups in the same region as the data, and test that a restored HSM can unwrap your data keys. A database backup without its keys cannot be read.

**Cold archives** of old partitions are written to object-locked storage in the region and verified by row count and checksum before the hot copy is removed. Restoring an archived partition is an operator command that loads it read-only into a temporary schema.

When a restored database comes up, the [region check at boot](./regions#the-region-check-at-boot) refuses to start a node whose `RELAY_REGION` does not match the region recorded in the database.

## Upgrades

Every release ships its database migrations, and they run as a separate step before the new nodes start. With Helm, a migration job (`Relay.Release.migrate()`) runs on each upgrade with the migrator credentials; with compose, run the migration command before restarting the nodes.

Migrations follow the expand and contract pattern: each release works with both the previous and the new schema, so old and new nodes can serve traffic side by side during a rolling upgrade, and you can roll the application back without rolling the schema back. Columns are added in a compatible way, constraints are validated in a second step and indexes are built concurrently. Adding a column to a partitioned table takes a lock on every partition, so run such upgrades at a quiet hour. The job queue's own schema migration runs before the application code, which is the one documented exception.

Do not skip the migration step and do not edit migrations by hand.

## Partition maintenance

Large tables are partitioned by time, and a maintenance task creates future partitions ahead of time. The `RelayPartitionHorizon` alert fires when future partitions run short. Treat it as urgent: when no partition exists for incoming rows, writes fail. Expired partitions are detached and moved to the cold archive automatically, one at a time.

## Kill switch access

A kill switch stops sending for the whole installation, a tenant, a campaign, a workflow, an API client or a sender. There are four ways to reach it, so losing one component does not take them all away:

1. **The API:** `POST /v1/operator/kill_switches` and its `replace` and `release` actions, with an operator session.
2. **The command line:** `relay kill-switch engage`, `replace`, `release`, `list` and `get`. See [Command line](/guide/cli).
3. **The console:** the kill switch page under governance.
4. **The emergency database procedure**, for when the API and console are down: an operator calls the same kill switch database functions directly and then publishes the new generation on the kill switch signal channel in Valkey. It writes the same record and the same audit entry as the other paths. The procedure is kept as a runbook in the repository's `runbooks/` folder.

Every path names the operator and a reason, and every engagement needs a time limit or an explicit approval to run without one.

## Incident communication outside Relay

Relay must not depend on itself to tell people it is broken.

- **Status page:** publish a static status page, hosted somewhere that shares nothing with your Relay installation. The repository has the page template and a publishing script; where you host it is your choice.
- **Paging:** wake your on-call engineers through a paging provider outside Relay. Alertmanager receivers are plain webhooks, so any provider works. Watch your paging provider's own status page too.
- **Wake-up channels:** use mobile push and voice calls first. SMS must not be the primary way to wake someone. Test each engineer's wake-up path with a scheduled test alert every week before relying on it.
- **Email to customers:** send incident email from a separate account and sender reputation, not through Relay. A banner in the console is not a reliable channel.

## Runbooks

Every alert links to a runbook, and runbooks live in the repository's `runbooks/` folder, one Markdown file per alert or procedure. Each starts with a header naming its severity, channels, scope, the alerts it covers and when it was last tested, followed by six fixed sections: symptom, impact, diagnosis, decision tree, mitigation, and fix and escalation. CI rejects a runbook that is incomplete or has not been tested for six months, and an alert without a runbook.

Runbooks must be readable when your infrastructure is not. Each change on the main branch builds the whole set as a single HTML file, attached to the workflow run and to each release. Keep a current copy somewhere that does not depend on your installation.

## Memory

Run each node with a container memory limit (the Helm chart sets one) and keep the Erlang VM's memory at about 75% of that limit, leaving room for the operating system and spikes. Alert when a container uses more than 75% of its limit for 15 minutes, and page when it passes 90%.

## Scaling

Scale on work waiting, not on CPU. Relay exposes the age of the oldest waiting job and the number of waiting jobs per lane, and the Helm chart can deploy an optional KEDA `ScaledObject` that scales the workers on those two signals. Notification workers mostly wait on providers, so CPU says little about whether they keep up.

Adding nodes does not help a lane whose provider circuit breaker is open: the provider is refusing work, and more workers would only wait longer. Look at the breaker first.

When nodes scale automatically, check the [connection pooling rule](./postgres#connection-pooling).

## Graceful shutdown

When a node receives `SIGTERM` it shuts down in a fixed order, so no accepted request is lost:

1. The readiness probe starts answering `503` at once.
2. The node waits 10 seconds for the load balancer to take it out of rotation.
3. Queues stop taking new jobs, and running jobs get up to 30 seconds to finish. A job that does not finish returns to the queue when its lease ends and another node runs it.
4. Realtime connections are closed in batches spread over 15 seconds, each with a hint to reconnect after a random delay, so clients do not all reconnect at the same moment.
5. The process exits.

The order lives in the application, so the Helm chart has no `preStop` hook. Its `terminationGracePeriodSeconds` is 75: the 10, 30 and 15 seconds above plus 20 seconds of margin. Deployments roll with `maxUnavailable: 0` and `maxSurge: 25%`, so capacity never drops during an upgrade. If you deploy another way, keep the grace period at least as long.
