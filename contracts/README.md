# Relay contracts

Hand-written, reviewed contracts for Relay's public surfaces. The server is tested against these files on every CI run, SDKs are generated from them, and a breaking change against `main` fails the build.

## Layout

```
contracts/
├── errors.yaml                 # single error catalog
├── openapi/
│   ├── server.yaml             # sending, management and query (tenant backends, operator sessions)
│   ├── subscriber.yaml         # client family (browser, mobile, UI components, webhook portal)
│   ├── operator.yaml           # operator family (Access OIDC session, step-up, platform actions)
│   └── components/
│       ├── schemas.yaml        # shared resource and value schemas, identifier formats
│       ├── problem.yaml        # RFC 9457 problem details and field errors
│       ├── parameters.yaml     # shared headers, path and pagination parameters
│       ├── headers.yaml        # shared response headers
│       └── responses.yaml      # shared error responses
├── asyncapi/
│   └── events.yaml             # single event catalog: webhooks, realtime, audit actions, Access events
├── mcp/
│   └── tools.yaml              # tool catalogue of the MCP server: each tool is one server operation
├── access/
│   └── relay-message.v1.schema.json  # Access's messages to Relay (vendored, never edited here)
└── connectors/
    └── outbox.sql              # table shape of the PostgreSQL outbox source of ingest connectors
```

- **OpenAPI 3.1** with JSON Schema 2020-12 for HTTP families; **AsyncAPI 3.1** for the event catalog.
- Every family lives in its own file and has its own authentication rule. The agent family is added in a later stage.
- `connectors/outbox.sql` is the table a producer exposes to Relay's built-in ingest source: `id` orders the rows, `payload` holds one structured mode CloudEvent, and Relay writes `relay_claimed_until`, `relayed_at` and `relay_outcome`. The producer names the table and may add columns of its own. Relay checks the columns and types when it connects, reads and updates rows, and never deletes one.

## Access's messages

`access/relay-message.v1.schema.json` is an exact copy of Access's own contract for the CloudEvents it posts to `POST /v1/events` (`crates/identity-account/contracts/relay-message.v1.schema.json` in the Access repository, taken at Access commit `aa533324d`, where the file was last changed in `1a42b8743`). Relay validates every `relay.message.*.v1` event of the Access platform tenant against it. It is replaced only by copying a newer Access version over it, never edited here.

## Discovery

`server.yaml` also describes the public discovery document, `GET /.well-known/relay-configuration`, and the product event key set, `GET /.well-known/relay-jwks.json`. A client finds the document from its Access issuer: `suiss_relay` in the Access Suiss discovery document is the Relay `issuer`, and the document lives at `<suiss_relay>/.well-known/relay-configuration`. Capability URNs use the `urn:suiss:relay:` prefix.

## Conventions

- Every request schema sets `additionalProperties: false`: unknown fields are rejected with `422 unknown_field`, never ignored.
- Errors are `application/problem+json`. The problem `type` is `<region base URL>/v1/errors/<code>`, served unauthenticated by Relay itself from `errors.yaml`.
- Identifiers are prefixed, opaque and time ordered; the prefix table is `x-relay-id-prefixes` in `server.yaml`.
- Per-operation extensions:
  - `x-relay-scopes`: Access API client scopes that grant the operation (any one of them).
  - `x-relay-role`: minimum operator role when an operator session is used.
  - `x-relay-role-by-change`: for an operation whose change can tighten or relax, the operator roles that may `lower` (tighten) and `raise` (relax, remove or create) it.
  - `x-relay-weight`: API rate limit weight (`rows` for batches).
  - `x-relay-idempotency`: `required`, `derived` (CloudEvents and webhook ids) or `not_applicable`.
  - `x-relay-step-up`: `false`, `always` or `conditional` (with `x-relay-step-up-when`).
  - `x-relay-errors`: error codes the operation can return; each must exist in `errors.yaml`.
- `x-relay-choice: true` marks a value or name the contract chose where the product decisions are silent. Each carries an `x-relay-choice-note` and is reviewed before dependent code is written.

## Verifying a webhook

Relay signs every HTTPS delivery with the Suiss webhook profile, which is compatible with Standard Webhooks and shared with Access, so one verifier accepts the events of both products. The profile is written out in `asyncapi/events.yaml` under `x-relay-webhook-profile`; a consumer follows these rules:

- Verify the signature over the raw body exactly as it arrived. The signed content is `{webhook-id}.{webhook-timestamp}.{raw body}`; a body that was parsed and serialised again does not verify.
- Compare signatures in constant time.
- Refuse a `webhook-timestamp` more than five minutes from your clock, in either direction. Every attempt carries a new timestamp; when the event happened is `time` in the body.
- `webhook-signature` is a space separated list. During a key rotation overlap it carries one signature per key; accept the message when any of them verifies against any key you hold for the endpoint. `v1a` (Ed25519, the default) verifies with the endpoint's `whpk_` public key, `v1` (HMAC-SHA256, compatibility only) with its `whsec_` secret.
- Keep every `webhook-id` for at least 96 hours, longer than the retry window, and process an identifier only once. Delivery is at least once and in no guaranteed order: the same event can arrive again, and the definite state is always read from the API.
- The unsigned headers `webhook-event-type` and `webhook-attempt` are a convenience for routing and logging. They are not covered by the signature and carry no security meaning.
- Answer `2xx` as soon as the event is stored and do the work afterwards. A redirect is never followed.

For local development `relay listen --forward-to <url>` reads the environment's events from `GET /v1/webhook_events` and posts each one to a loopback address with the same headers. It signs with `v1` and a secret of the listening session (`RELAY_LISTEN_SECRET`, or one printed when the command starts), so the verification code of the application runs unchanged; Relay itself never calls a developer machine.

Relay verifies inbound messages of the profile with the same verifier it uses for its own deliveries. The shared test vectors are in `conformance/webhooks/vectors/`.

## Changing a contract

1. Edit the YAML; keep field names, codes and identifiers consistent across files.
2. Within a dated version only additions are allowed; removals, renames and meaning changes need a new version.
3. Run the contract checks in CI; they compare against `main` and stop breaking changes.
4. A breaking change that was decided on purpose is listed, one change per line, in `openapi/breaking-accepted.txt` in the same pull request; the check skips only the listed changes.
