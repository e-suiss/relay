# Operations

These pages are for the people who run Relay: the Suiss team operating the hosted regions, and you, if you run Relay yourself. They describe where data lives, how the database survives failures, how keys are held, how to upgrade and scale, and how to move from another notification system without losing or doubling a message.

Relay always runs next to Access, the Suiss identity product. Every installation is linked to an Access installation in the same region, and Access stays the authority for identities, tenants and permissions.

## Hosted or self-hosted: the same product

The hosted service and a self-hosted installation run the same release, built from the same code, with the same features. Nothing is held back for the hosted service and nothing is unlocked by a licence key: kill switches, the in-app inbox, webhook replay, the preference centre, the console with single sign-on and roles, the activity log and every agent feature ship in the open-source release.

What the hosted service adds is service, not features:

- shared provider accounts and sender reputation that is already warmed up;
- operation in several regions, with an availability commitment;
- a managed connection to İYS, the Turkish commercial message consent registry;
- backups, upgrades and an on-call team, run for you.

If you run Relay yourself, these are your responsibilities, and the pages in this section tell you how Relay expects them to be done.

## What you will find here

- [Regions and data residency](./regions): region codes, base addresses, the boot-time region check and how a region is accepted before it opens.
- [Front layer and TLS](./front-layer): where a CDN, WAF or tunnel may sit, and where TLS may end.
- [Static egress IPs](./egress-ips): the outbound addresses providers and webhook receivers can allow.
- [Licensed tenants in Türkiye](./licensed-tenants): a deployment guide for banks, payment and e-money institutions.
- [PostgreSQL HA and recovery](./postgres): high availability, point-in-time recovery, recovery targets and connection pooling.
- [Keys, HSM and BYOK](./keys): how keys are held and how a tenant brings its own key.
- [Self-host operations](./self-host): backup and restore, upgrades, alarms, kill switch access, incident communication, scaling and shutdown.
- [Capacity](./capacity): the working capacity assumptions and what to do when one database is not enough.
- [Portability](./portability): how your data and your operation stay yours.
- [Migration guide](./migration): shadow mode, staged rollout, imports and cutover.
