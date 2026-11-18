# Guarantees and idempotency

Relay provides at-least-once delivery with durable idempotency, giving effectively-once processing.

That one sentence is the whole promise. Networks fail between any two systems, so a message can be sent more than once; what Relay guarantees is that it is never lost once accepted, and that repeating a request never repeats its effect.

## Accepted means durable

`202 Accepted` means the event, its notifications and the work to deliver them are committed in one database transaction. From then on Relay keeps trying, under the retry schedules on the [limits page](/reference/limits), until each delivery reaches a final state. Acceptance is not delivery: policy decisions and provider answers come afterwards and are recorded on each delivery.

## Idempotency keys

Every `POST`, `PUT`, `PATCH` and `DELETE` carries an `Idempotency-Key` header. Relay stores the first response for the key for 24 hours. A repeat with the same key and body gets that stored response byte for byte, with `Idempotency-Replayed: true`, and changes nothing:

<<< @/examples/curl/idempotency.sh

Use a key that names your business operation, such as `order:4821:shipped`, so a retry from another process or after a crash is recognised too. The same key with a different body is refused with `idempotency_key_reuse`, and a request still in progress with the same key gets `idempotency_key_in_progress`, which is safe to retry.

CloudEvents need no header: the key is derived from the event's `source` and `id`, so a CDC pipeline that sends the same change twice opens one event.

A `dedup_key` on an event is a business key at a different level: the same key opens no second notification for the same recipient, even across different requests.

## Retries

Every error is an RFC 9457 problem document with a stable `code` and a `retryable` flag. Retry only when `retryable` is `true`, honour `Retry-After`, and otherwise back off exponentially with full jitter. Relay's SDKs do exactly this, keeping the same `Idempotency-Key` across retries:

<<< @/examples/curl/problem.sh

Each code has a page at `/v1/errors/{code}` on the same region:

<<< @/examples/curl/error-catalog.sh

A refused limit names itself: the problem carries `limit_name`, `limit` and `actual`. Every limit is listed on the [limits page](/reference/limits) and every code in the [error catalog](/reference/errors).

## Decisions are not errors

A message skipped because of consent, a preference, quiet hours or a kill switch is not an error. The request is accepted, and the skip is recorded on the delivery as a decision with a `rule_id`. Your code never has to treat a policy outcome as a failure.

## Your side of the bargain

At-least-once has a consequence: a webhook can reach you more than once and in any order.

- Deduplicate by `webhook-id` and keep it for at least 96 hours, longer than the retry window.
- Answer `2xx` only after you have stored the event.
- Read the definite state from the API with the ids in the event, rather than trusting the order events arrive in.

See [Webhooks](./webhooks) for verification code in every SDK language.
