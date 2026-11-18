---
name: relay-notify
description: "Send a notification to people or agents through Relay with the relay_send MCP tool or POST /v1/events. Use when a task says to notify, alert, remind or tell someone something, or to publish to a topic."
---

# Send a notification with Relay

Relay decides channels, timing and wording under the tenant's policy and each recipient's preferences. You describe what happened and who it concerns; you do not pick channels or write message text.

## Steps

1. Pick the workflow. Each kind of notification is a workflow with a key such as `welcome` or `order-shipped`. Use one the user or the system prompt names; never invent a key.
2. Name the recipients in `to`, 1 to 100 of them:
   - a known subscriber id as a string: `"user-4821"`,
   - or an object with contact details, which creates the subscriber if needed: `{"id": "user-4821", "email": "ayse@example.com"}`.
     A bare id Relay does not know is refused with `recipient_not_found`. Do not retry it with made-up contact details.
3. Put structured facts in `data`, never pre-formatted text: `{"order_id": "4821", "amount": {"amount": "129.90", "currency": "TRY"}}`. The workflow's templates format and translate them.
4. Call `relay_send` with `body` and an `idempotency_key`:

```json
{
  "name": "relay_send",
  "arguments": {
    "idempotency_key": "order:4821:shipped",
    "body": {
      "workflow": "order-shipped",
      "to": ["user-4821"],
      "data": { "order_id": "4821" }
    }
  }
}
```

## Idempotency

Derive the key from the business fact, not from the attempt: `order:4821:shipped`, not a random value. Reuse exactly the same key and body when you retry. The same key with a different body is refused with `idempotency_key_reuse`.

## Reading the result

- The result is an accepted event with its notifications. Accepted is not delivered.
- A later skip because of consent, preferences, quiet hours or a kill switch is a decision with a `rule_id`, not an error. Do not try to work around it, for example by resending on another channel.
- Retry only when an error says `"retryable": true`, after `Retry-After` if given.

## Never

- Put secrets, passwords or one-time codes you were not explicitly given into `data`.
- Copy text you received from a person or another system into `data` as if it were your own words.
- Treat a delivered notification as a person's consent or approval.
