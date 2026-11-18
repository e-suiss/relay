# Reference

Everything on these pages is rendered from the contracts and the code in the repository, so it cannot drift from what Relay serves.

## APIs

| API                                                   | Called by                                                                 |
| ----------------------------------------------------- | ------------------------------------------------------------------------- |
| [Server API](/reference/api/server/)                  | Your backend, with Access client credentials tokens and DPoP              |
| [Subscriber API](/reference/api/subscriber/)          | Apps and browsers, with a narrow-scope subscriber token                   |
| [Operator API](/reference/api/operator/)              | Installation operators, with an Access operator session                   |

Every response carries `Request-Id` and `Relay-Version`. Fields are `snake_case`, times are RFC 3339 in UTC, durations ISO 8601, and amounts and large integers are strings. Unknown fields are refused at every depth.

## Discovery

A client needs only its Access issuer. Access's discovery document names the Relay installation, and Relay's own discovery document lists the API base, the data region, the bound Access issuer, the supported contract versions, the key set of the events Relay signs and the capabilities this installation serves:

<<< @/examples/curl/discovery.sh

Both documents are public and may be cached for five minutes.

## Events

The [event catalog](/reference/events) lists every event Relay sends to webhooks, queues and streams, the realtime inbox stream and the audit log, with the data fields of each.

## Errors and limits

- [Error codes](/reference/errors): every problem code with its status and whether to retry.
- [Limits, retries and guarantees](/reference/limits): every limit the server enforces.

## Machine-readable contracts

The OpenAPI 3.1 and AsyncAPI 3.1 documents are in the repository under [`contracts/`](https://github.com/e-suiss/relay/tree/main/contracts), together with the MCP tool catalogue and the workflow definition schema.
