# Local development

Relay runs locally with one command and the official Docker Compose file in `deploy/compose.yaml`. There is no separate development mode: the local node runs the same code, the same checks and the same pipeline as production. Only its surroundings are local.

```sh
just dev
```

## What runs

| Service    | Address                  | Purpose                                        |
| ---------- | ------------------------ | ---------------------------------------------- |
| Relay      | `http://localhost:4000`  | The API, realtime and webhooks                 |
| PostgreSQL | `localhost:5432`         | Every source of truth                          |
| Valkey     | `localhost:6379`         | Signals, counters and rate limits              |
| MinIO      | `http://localhost:9001`  | The write-once store of audit checkpoints      |
| Mailpit    | `http://localhost:8025`  | Catches every email a local SMTP account sends |
| APNs mock  | `https://localhost:8443` | Answers like Apple Push Notification service   |
| FCM mock   | `http://localhost:8081`  | Answers like Firebase Cloud Messaging          |
| SMS mock   | `http://localhost:8082`  | Answers like an SMS provider                   |
| Toxiproxy  | `http://localhost:8474`  | Network fault injection (`just chaos`)         |
| Jaeger     | `http://localhost:16686` | Traces                                         |
| Prometheus | `http://localhost:9090`  | Metrics and alert rules                        |
| Grafana    | `http://localhost:3000`  | Dashboards                                     |

Keys live in a local SoftHSM token, exactly as they would in a hardware security module in production. Relay never reads a key from a file or an environment variable.

## Access, locally

Relay always works with Access, the identity platform of Suiss: API clients, operators and subscriber tokens all come from it. Locally, a stand-in answers for the Access issuer `https://access.localhost`. It publishes the discovery documents and a key set, and signs tokens for the sample API client. Relay still verifies every token through the Access link exactly as in production.

To run against a real Access instead, start it with `just access` and set `RELAY_ACCESS_ISSUER`.

## Tokens for requests

<<< @/examples/curl/env.sh

`mix relay.dev.token` prints a token of the sample `test` API client and `mix relay.dev.proof` the DPoP proof of one request. Both only read the configuration, so they run next to a running node.

An SDK needs the same two things: a token and the key it is bound to. This helper gives the TypeScript SDK the local stand-in's key and the token from `TOKEN`; in production, your Access client credentials and your own key take their place:

<<< @/examples/typescript/credentials.ts

## The test plane

Every tenant has a `live` and a `test` environment. On `test`, the fake provider answers in place of real providers and a virtual clock lets you move time forward for scheduled sends, digests and waitpoints. The virtual clock and the fake provider never exist on `live`.

## Useful commands

```sh
just test     # the test suite against the real database
just check    # every check CI runs on a pull request
just chaos    # start Toxiproxy to inject network faults
just down     # stop the local services
```
