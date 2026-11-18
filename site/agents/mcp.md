# MCP server

Relay serves a [Model Context Protocol](https://modelcontextprotocol.io) server at `POST /v1/mcp`, protocol revision `2026-07-28`. It is stateless: one JSON-RPC request per HTTP call, no session, no stream and no request from the server back to the client, so it uses neither sampling nor elicitation. It offers tools and nothing else.

## Tools

| Tool                           | What it does                                                         | Operation             |
| ------------------------------ | -------------------------------------------------------------------- | --------------------- |
| `relay_send`                   | Send an event to its recipients                                      | `createEvent`         |
| `relay_open_waitpoint`         | Open a waitpoint for a response or an event                          | `createWaitpoint`     |
| `relay_read_waitpoint`         | Read a waitpoint's state and the response that resolved it           | `getWaitpoint`        |
| `relay_list_awaiting_response` | List the open and stalled waitpoints                                 | `listWaitpoints`      |
| `relay_read_mailbox`           | Read mailbox records after a position, without taking a lease        | `listMailboxRecords`  |
| `relay_lease_mailbox`          | Take the next mailbox records under a lease                          | `leaseMailboxRecords` |
| `relay_ack_mailbox`            | Acknowledge records of one lease                                     | `ackMailboxRecords`   |
| `relay_subscribe_topic`        | Subscribe recipients to a topic                                      | `addTopicSubscriptions` |

Each tool is one operation of the [server API](/reference/api/server/) and runs under its scopes, limits, idempotency and policy decisions. `tools/list` shows only the tools your credential's scopes grant. No tool answers a waitpoint, and nothing obtained through MCP is ever an authorisation.

## Requests

Authenticate like any server API call, with an Access token and a DPoP proof. Every request names its protocol version in the `MCP-Protocol-Version` header and in `params._meta`, its method in `Mcp-Method` and, for `tools/call`, the tool in `Mcp-Name`. The methods are `server/discover`, `tools/list` and `tools/call`.

List the tools your credential may call:

<<< @/examples/curl/mcp-tools.sh

Call one. A tool whose operation needs an idempotency key takes it as the `idempotency_key` argument, and the operation's request body as `body`:

<<< @/examples/curl/mcp-send.sh

## Errors

| Situation                                       | Answer                                     |
| ----------------------------------------------- | ------------------------------------------ |
| Header and body disagree                        | JSON-RPC error `-32020`, HTTP `400`        |
| A protocol version Relay does not serve         | JSON-RPC error `-32022`, HTTP `400`        |
| An unknown method                               | JSON-RPC error `-32601`, HTTP `404`        |
| An unknown tool                                 | JSON-RPC error `-32602`                    |
| A tool your scopes do not grant                 | Refused in the tool result                 |

## Tasks

A waitpoint in a result carries, under `_meta`, the state the MCP tasks extension gives it: `input_required` while a question or review is open, so a client that tracks tasks sees the waitpoint as that task's state. Relay itself never answers `input_required`.

## Connect an agent

Point your MCP client at `https://<your relay>/v1/mcp` with a credential from your Access API client, and give the agent the [skills package](./skills) so it knows how to use the tools well.
