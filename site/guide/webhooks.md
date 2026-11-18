# Webhooks

Relay tells your systems what happened to notifications, deliveries, devices, addresses and more by sending signed events to your webhook endpoints, or to queues and streams such as Kafka, NATS, RabbitMQ, SQS, SNS, EventBridge, Pub/Sub, Service Bus and S3. Every event type is listed in the [event catalog](/reference/events).

## What an event looks like

Each event is a CloudEvents 1.0 structured JSON envelope: `id` (the same as the `webhook-id` header), `source` (your Relay installation), `type` (such as `notification.delivered`), `time`, `subject`, `dataschema`, a per-subject `seq` and `environment` (`live` or `test`). Payloads are thin: identifiers and states, never personal data. Read details from the API with the ids.

## The signature

HTTPS deliveries follow the Suiss webhook profile, compatible with Standard Webhooks:

| Header              | Meaning                                                                                   |
| ------------------- | ----------------------------------------------------------------------------------------- |
| `webhook-id`        | The event id; the same on every attempt, resend and replay                                |
| `webhook-timestamp` | Unix seconds of this attempt                                                              |
| `webhook-signature` | Space-separated signatures: `v1a,<base64 Ed25519>` (default) or `v1,<base64 HMAC-SHA256>` |

The signed content is `{webhook-id}.{webhook-timestamp}.{raw body}`. Ed25519 is the default: the private key never leaves Relay's key store, and you verify with the endpoint's public key, `whpk_…`. HMAC with a `whsec_…` secret exists only for compatibility. During a key rotation there are two signatures; accept the message when any of them verifies with any key you hold.

## Verify

Always verify the raw body exactly as it arrived, before parsing it. Every server SDK ships a verifier that checks the signature in constant time and refuses timestamps more than five minutes away.

::: code-group

<<< @/examples/typescript/webhook.ts#verify [TypeScript]

<<< @/examples/python/webhook.py#verify [Python]

<<< @/examples/go/snippets.go#verify [Go]

<<< @/examples/dotnet/Webhooks.cs#verify [.NET]

<<< @/examples/java/snippets/Webhooks.java#verify [Java]

<<< @/examples/elixir/webhooks.ex#verify{elixir} [Elixir]

:::

## Process each event once

Delivery is at least once and in no guaranteed order.

- Keep each `webhook-id` for at least 96 hours and drop events you already processed.
- Answer `2xx` once the event is stored. Answer quickly and do the work afterwards.
- Read the definite state from the API: the event tells you that something changed, the API tells you what is true now. `seq` lets you see gaps and order per subject.
- Never base a security decision on an unsigned header such as `webhook-event-type`.

## Answers Relay understands

| Your answer                              | What Relay does                                               |
| ---------------------------------------- | ------------------------------------------------------------- |
| `2xx`                                    | Delivered                                                     |
| `410 Gone`                               | Disables the endpoint                                         |
| Header `webhook-delivery: abort-message` | Stops retrying this one message                               |
| Anything else, a timeout or a redirect   | Retries on the webhook schedule; redirects are never followed |

The retry schedule is on the [limits page](/reference/limits). Failed messages can be replayed from the console or the API after you fix your endpoint, and each replay carries the original `webhook-id`.

## Local development

`relay listen --forward-to http://localhost:3000/relay` forwards your tenant's webhook events to a local address, signed exactly as in production. See [Command line](./cli).
