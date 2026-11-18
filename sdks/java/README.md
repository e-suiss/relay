# Relay Java SDK

Java client for the Relay server API: send events, manage workflows and subscribers, wait on
agent waitpoints, read agent mailboxes and verify Relay webhooks.

- Every operation of the server API, generated from the OpenAPI contract
- Pinned to API version `2026-11-01`: upgrading the package never changes the API behaviour you get
- Automatic `Idempotency-Key` on every mutating request, reused on every retry
- Retries only errors Relay marks `retryable`, with exponential backoff, full jitter and `Retry-After`
- Typed errors: authentication, validation, rate limit and quota, idempotency, server
- Lazy pagination
- DPoP-bound Access tokens with Ed25519 proofs
- Raw-body webhook verifier for Ed25519 (`v1a`) and HMAC (`v1`) signatures
- Java 17 or later; the only dependency is Jackson

## Install

Gradle:

```kotlin
implementation("app.suiss:esuiss-relay:0.1.0")
```

Maven:

```xml
<dependency>
  <groupId>app.suiss</groupId>
  <artifactId>esuiss-relay</artifactId>
  <version>0.1.0</version>
</dependency>
```

## Quick start

Relay accepts Access access tokens bound to a key with DPoP. The SDK obtains them with your API
client's credentials and signs a fresh proof for every request.

```java
DpopKey key = DpopKey.generate();

RelayClient relay = RelayClient.builder()
    .baseUrl("https://relay.example.com")
    .credentials(DpopCredentials.of(key, AccessTokenSource.builder()
        .tokenEndpoint(URI.create("https://access.example.com/oauth2/token"))
        .clientId(System.getenv("ACCESS_CLIENT_ID"))
        .clientSecret(System.getenv("ACCESS_CLIENT_SECRET"))
        .resource(System.getenv("RELAY_ACCESS_CLIENT_ID"))
        .key(key)
        .build()))
    .build();

ObjectNode event = Json.object().put("workflow", "order-shipped");
event.putArray("to").add("customer-4821");
event.putObject("data").put("order", "4821");
JsonNode accepted = relay.api().createEvent(event);
```

`resource` is Relay's Access client id, `access_client_id` in
`https://<relay>/.well-known/relay-configuration`.

## Requests

Every operation is a method on `relay.api()`, named after its `operationId`. Path parameters come
first, then query parameters, then the body, then `RequestOptions`:

```java
JsonNode waitpoint = relay.api().getWaitpoint("wp_01jc4x0f8c2q4a7r5w3v9y6k1m");

relay.api().updateSubscriber(
    "sub_01jc4x0f8c2q4a7r5w3v9y6k1m",
    Json.object().put("locale", "tr-TR"),
    RequestOptions.builder().idempotencyKey("profile-sync-4821").build());
```

Bodies and responses are Jackson `JsonNode`s; read them into your own types with `Json.mapper()`.

## Idempotency and retries

Mutating requests get a random `Idempotency-Key` once per call; every retry of that call sends the
same key, so Relay processes the request effectively once. Pass your own key with
`RequestOptions.builder().idempotencyKey(...)` to make a call safe to repeat across processes.

Only errors whose problem body says `"retryable": true` are retried, by default up to 3 times. The
wait is the `Retry-After` Relay sent or, without it, a random time below an exponential ceiling.

```java
RelayClient relay = RelayClient.builder()
    .baseUrl("https://relay.example.com")
    .credentials(credentials)
    .maxRetries(5)
    .build();
```

## Errors

Every failure is a `RelayException`. Relay's problem details arrive as an `ApiException` subclass:

| Exception | When |
|---|---|
| `AuthenticationException` | missing, invalid or expired credentials, insufficient scope |
| `ValidationException` | malformed request, unknown field, failed validation |
| `RateLimitException` | rate limited (retried automatically) |
| `QuotaException` | sending quota exhausted (a `RateLimitException`, never retried) |
| `IdempotencyException` | idempotency key missing, invalid, reused or in progress |
| `NotFoundException` | the resource does not exist |
| `ConflictException` | conflict or failed precondition |
| `ServerException` | Relay could not answer |

`ConnectionException` means no response arrived.

```java
try {
  relay.api().createEvent(event);
} catch (ValidationException e) {
  log.warn("refused: {} {} ({})", e.code(), e.detail(), e.requestId());
}
```

## Pagination

List operations return a `Page`. `autoPaging()` walks every item and fetches the next page only
when it is needed.

```java
for (JsonNode waitpoint : relay.api().listWaitpoints().autoPaging()) {
  System.out.println(waitpoint.path("id").asText());
}
```

## Agents

```java
Agents agents = relay.agents();

JsonNode waitpoint = agents.createWaitpoint(request,
    RequestOptions.builder().idempotencyKey("approval-4821").build());
JsonNode done = agents.awaitWaitpoint(
    waitpoint.path("id").asText(), Duration.ofMinutes(10), Duration.ofSeconds(2));

JsonNode lease = agents.leaseMailbox(10);
agents.ackMailbox(lease.path("lease_id").asText(), recordIds);
```

A wake hint (a webhook, a push) only says that something arrived; the mailbox holds the records.
`follow` opens the hint stream first, reads the history, then reads again after every hint, and
hands each record to the handler once:

```java
agents.follow(hints, record -> handle(record));
```

Use `agents.mailboxFeed(handler)` and call `catchUp()` from your own webhook handler when hints
arrive as callbacks.

## Webhooks

Verify the raw body before parsing it. Relay sends `webhook-id`, `webhook-timestamp` and
`webhook-signature`; a message is accepted when any signature verifies with any configured key and
its timestamp is within 5 minutes.

```java
WebhookVerifier verifier = WebhookVerifier.builder()
    .key(System.getenv("RELAY_WEBHOOK_PUBLIC_KEY"))
    .build();

try {
  VerifiedWebhook webhook = verifier.verify(headers, rawBody);
  if (alreadyProcessed(webhook.id())) {
    return 200;
  }
  process(rawBody);
} catch (WebhookVerificationException e) {
  return 400;
}
```

Keep processed `webhook-id`s for at least 96 hours: delivery is at least once, and a retry can
arrive days later.

## Development

The generated sources (`RelayApi`, `ApiVersion`, `ErrorCatalog`, `params/*`) come from
`contracts/openapi/server.yaml` and `contracts/errors.yaml`:

```sh
gradle generate spotlessApply
gradle build
```

Dependencies are locked (`gradle.lockfile`) and verified (`gradle/verification-metadata.xml`).

## License

Apache-2.0
