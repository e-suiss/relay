# Regions and data residency

The hosted service runs as fully separate installations, one per region. A tenant picks its region when it is created, and its data stays there for its whole life.

## Region codes and base addresses

| Region  | Code | Base address                 |
| ------- | ---- | ---------------------------- |
| Türkiye | `tr` | `https://tr.relay.suiss.app` |
| Europe  | `eu` | `https://eu.relay.suiss.app` |
| USA     | `us` | `https://us.relay.suiss.app` |

The base address is where the API, the console, the realtime socket and the discovery document of that region live. A self-hosted installation chooses its own base address and its own short region code.

The region of an installation never changes. The discovery document at `/.well-known/relay-configuration` reports it as `region`, next to `api_base`, so a client can confirm which region it is talking to.

## Nothing crosses a region

Each region has its own PostgreSQL, its own Valkey and its own key store (HSM). None of them is shared with another region, and there is no replication, backup copy or copy of operational data from one region to another. Disaster recovery happens inside the region. Where a view across regions is needed, it is built by asking each region, never by moving data.

The Access installation a region is linked to is in the same region, and the two are installed together from the same package.

## The Türkiye region stays in Türkiye

The Türkiye region runs in a data centre or on a cloud located in Türkiye. Its database backups, its key backups and its telemetry (logs, metrics and traces) stay in Türkiye as well. The providers chosen by default for the region are ones that process data in Türkiye, and the front layer follows the same rule: see [Front layer and TLS](./front-layer).

## The region check at boot

Each node reads its region code from `RELAY_REGION` (`tr`, `eu` or `us` in the hosted service; any short code you choose when self-hosting) and compares it with the region recorded in its database. If they differ, the node refuses to start. A node pointed at the wrong database, or a database restored into the wrong region, therefore never serves traffic.

## Requests for another region

A token or a request that belongs to a tenant of another region is refused with `421 Misdirected Request` and the error code `wrong_region`. Relay never redirects or forwards the request, because forwarding would carry the request's data across a region boundary. Send the request to the base address of the tenant's own region instead; the SDKs take the base address as configuration for this reason.

## Accepting a region

A region is opened for new tenants only after it has passed the region acceptance test. The test is a manually started GitHub Actions workflow named `region-acceptance` that runs against the target region and reports how long each step took:

1. tenant isolation tests;
2. a kill switch propagation drill;
3. a database failover drill;
4. an archive and restore drill;
5. an end-to-end send in shadow mode.

The same suite runs every night against the local compose stack, so it does not rot between region openings. The failover and restore drills are also where the recovery targets on the [PostgreSQL page](./postgres) are measured.
