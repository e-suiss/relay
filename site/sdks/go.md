# Go

`github.com/e-suiss/relay/sdks/go` is the server SDK for Go 1.24 or later.

```sh
go get github.com/e-suiss/relay/sdks/go
```

## Send an event

`NewClientCredentials` obtains Access tokens with your API client's credentials and binds them to a DPoP key; every attempt carries a fresh proof.

<<< @/examples/go/snippets.go#quickstart

Every operation of the [server API](/reference/api/server/) is a method on `Client`, generated from the contract. Operations that take an `Idempotency-Key` get one that stays the same on every retry; pass `relay.WithIdempotencyKey` to choose it.

## Page through lists

<<< @/examples/go/snippets.go#decisions

The `...Iter` methods walk every page lazily; a `*relay.Page[T]` is also available for page-by-page reads.

## Errors

<<< @/examples/go/snippets.go#errors

Errors are typed: `*relay.AuthenticationError`, `*relay.ValidationError`, `*relay.RateLimitError`, `*relay.IdempotencyError` and `*relay.ServerError`, each unwrapping to `*relay.APIError` with Relay's problem details. Only problems marked `retryable: true` and requests that got no answer are retried.

## Verify webhooks

<<< @/examples/go/snippets.go#verify

`relay.NewWebhookVerifier` checks `v1a` (Ed25519) and `v1` (HMAC) signatures over the raw body and reports the scheme that verified.

## Agents

`OpenWaitpoint`, `AwaitWaitpoint`, `ReadMailbox`, `LeaseMailbox`, `AckMailbox`, `MergeMailbox` and `MergeStreamAndHistory` cover waitpoints, the mailbox and the follow pattern.
