# Python

`esuiss-relay` is the server SDK for Python 3.11 or later. Its only dependency is `cryptography`.

```sh
pip install esuiss-relay
```

## Send an event

`ClientCredentials(access_issuer, client_id, client_secret)` obtains Access tokens and binds them to an Ed25519 DPoP key; a token you obtained elsewhere works with `StaticToken(token, key)`. Locally, the example below uses a `StaticToken` minted by `mix relay.dev.token --jkt`.

<<< @/examples/python/send_event.py#send

Every operation of the [server API](/reference/api/server/) is a method on `Relay`, typed from the contract. Every write carries an `Idempotency-Key` that stays the same on every retry; pass `idempotency_key=` to choose it.

## Page through lists

<<< @/examples/python/send_event.py#decisions

Iterating a page fetches later pages only when needed.

## Errors

<<< @/examples/python/send_event.py#errors

Errors are typed: `AuthenticationError`, `ValidationError`, `RateLimitError`, `IdempotencyError` and `ServerError`, all carrying Relay's problem details. Only errors marked `retryable` are retried, with exponential backoff, full jitter and `Retry-After`.

## Verify webhooks

<<< @/examples/python/webhook.py#verify

## Agents

`create_and_await_waitpoint`, `mailbox_lease` and `mailbox_ack` cover waitpoints and the agent mailbox.
