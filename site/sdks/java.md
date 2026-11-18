# Java

`app.suiss:esuiss-relay` is the server SDK for Java 17 or later. Its only dependency is Jackson.

```kotlin install
implementation("app.suiss:esuiss-relay:0.1.0")
```

## Send an event

The SDK obtains Access tokens with your API client's credentials and signs a fresh DPoP proof for every request. `resource` is Relay's Access client id, `access_client_id` in `https://<relay>/.well-known/relay-configuration`.

<<< @/examples/java/snippets/Quickstart.java#quickstart

Every operation of the [server API](/reference/api/server/) is a method on `relay.api()`, named after its operation id: path parameters first, then query parameters, then the body, then `RequestOptions`. Bodies and responses are Jackson `JsonNode`s.

## Page through lists

<<< @/examples/java/snippets/Quickstart.java#decisions

`autoPaging()` fetches the next page only when it is needed.

## Errors

<<< @/examples/java/snippets/Quickstart.java#errors

Every failure is a `RelayException`. Relay's problem details arrive as an `ApiException` subclass: `AuthenticationException`, `ValidationException`, `RateLimitException` (retried automatically), `QuotaException` (never retried), `IdempotencyException`, `NotFoundException`, `ConflictException` or `ServerException`. `ConnectionException` means no response arrived.

## Verify webhooks

<<< @/examples/java/snippets/Webhooks.java#verify

## Agents

`relay.agents()` has `createWaitpoint`, `awaitWaitpoint`, `leaseMailbox`, `ackMailbox` and `follow`; use `mailboxFeed(handler)` and call `catchUp()` from your own webhook handler when wake-ups arrive as callbacks.
