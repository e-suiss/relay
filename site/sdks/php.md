# PHP

`esuiss/relay` is the server SDK for PHP 8.2 or later with the `curl`, `json` and `sodium` extensions, and no other dependencies.

```sh
composer require esuiss/relay
```

## Send an event

`ClientCredentials` obtains DPoP-bound Access tokens with your API client's credentials; every request carries a fresh proof.

<<< @/examples/php/Snippets.php#quickstart

Every operation of the [server API](/reference/api/server/) is a method on `Client`, generated from the contract. Every write carries an `Idempotency-Key` that stays the same on every retry; pass `idempotencyKey:` to choose it.

## Page through lists

<<< @/examples/php/Snippets.php#decisions

Iterating a `Page` walks every following page, fetching each one only when it is reached.

## Errors

<<< @/examples/php/Snippets.php#errors

Every problem answer becomes an `ApiException` subclass: `AuthenticationException`, `ValidationException`, `NotFoundException`, `ConflictException`, `RateLimitException`, `IdempotencyException` or `ServerException`, carrying the status, `errorCode`, `retryable`, `requestId` and the full problem body.

## Verify webhooks

<<< @/examples/php/Snippets.php#verify

## Agents

`openWaitpoint`, `awaitWaitpoint` and `consumeMailbox` cover waitpoints and the agent mailbox, and `Stream::merge()` implements the follow pattern.
