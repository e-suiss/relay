# Relay contracts

Hand-written, reviewed contracts for Relay's public surfaces. The server is tested against these files on every CI run, SDKs are generated from them, and a breaking change against `main` fails the build.

## Layout

```
contracts/
├── errors.yaml                 # single error catalog
├── openapi/
│   ├── server.yaml             # sending, management and query (tenant backends, operator sessions)
│   ├── subscriber.yaml         # client family (browser, mobile, UI components)
│   ├── operator.yaml           # operator family (Access OIDC session, step-up, platform actions)
│   └── components/
│       ├── schemas.yaml        # shared resource and value schemas, identifier formats
│       ├── problem.yaml        # RFC 9457 problem details and field errors
│       ├── parameters.yaml     # shared headers, path and pagination parameters
│       ├── headers.yaml        # shared response headers
│       └── responses.yaml      # shared error responses
└── asyncapi/
    └── events.yaml             # single event catalog: webhooks, realtime, audit actions, Access events
```

- **OpenAPI 3.1** with JSON Schema 2020-12 for HTTP families; **AsyncAPI 3.1** for the event catalog.
- Every family lives in its own file and has its own authentication rule. The agent family is added in a later stage.

## Conventions

- Every request schema sets `additionalProperties: false`: unknown fields are rejected with `422 unknown_field`, never ignored.
- Errors are `application/problem+json`. The problem `type` is `<region base URL>/v1/errors/<code>`, served unauthenticated by Relay itself from `errors.yaml`.
- Identifiers are prefixed, opaque and time ordered; the prefix table is `x-relay-id-prefixes` in `server.yaml`.
- Per-operation extensions:
  - `x-relay-scopes`: Access API client scopes that grant the operation (any one of them).
  - `x-relay-role`: minimum operator role when an operator session is used.
  - `x-relay-weight`: API rate limit weight (`rows` for batches).
  - `x-relay-idempotency`: `required`, `derived` (CloudEvents and webhook ids) or `not_applicable`.
  - `x-relay-step-up`: `false`, `always` or `conditional` (with `x-relay-step-up-when`).
  - `x-relay-errors`: error codes the operation can return; each must exist in `errors.yaml`.
- `x-relay-choice: true` marks a value or name the contract chose where the product decisions are silent. Each carries an `x-relay-choice-note` and is reviewed before dependent code is written.

## Changing a contract

1. Edit the YAML; keep field names, codes and identifiers consistent across files.
2. Within a dated version only additions are allowed; removals, renames and meaning changes need a new version.
3. Run the contract checks in CI; they compare against `main` and stop breaking changes.
