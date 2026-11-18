# Ruby

`esuiss-relay` is the server SDK for Ruby 3.2 or later, with no runtime dependencies.

```ruby install
gem "esuiss-relay"
```

## Send an event

`ClientCredentials` obtains DPoP-bound Access tokens with your API client's credentials; every request carries a fresh proof.

<<< @/examples/ruby/snippets.rb#quickstart

Every operation of the [server API](/reference/api/server/) is a method on `Esuiss::Relay::Client`, generated from the contract. Every write carries an `Idempotency-Key` that stays the same on every retry; pass `idempotency_key:` to choose it.

## Page through lists

<<< @/examples/ruby/snippets.rb#decisions

A list result is an `Enumerable` that fetches the next page only when needed.

## Errors

<<< @/examples/ruby/snippets.rb#errors

Errors are typed: `AuthenticationError`, `ValidationError` (with `NotFoundError` and `ConflictError`), `RateLimitError`, `IdempotencyError` and `ServerError`, all `APIError`s carrying Relay's problem details.

## Verify webhooks

<<< @/examples/ruby/snippets.rb#verify

Pass the raw request body, before any JSON parsing.

## Agents

`open_waitpoint`, `await_waitpoint` and `consume_mailbox` cover waitpoints and the agent mailbox.
