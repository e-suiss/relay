# esuiss/relay

PHP server SDK for Relay, the notification, messaging and event orchestration platform of Suiss.

- Every operation of the Relay server API, generated from its OpenAPI contract and pinned to its API version.
- Access client credentials with DPoP-bound tokens, handled for you.
- An `Idempotency-Key` on every mutating call, kept the same across retries.
- Retries only for problems Relay marks `retryable`, with exponential backoff, full jitter and `Retry-After`.
- Typed exceptions, lazy pagination, a raw-body webhook verifier and agent helpers.

Requires PHP 8.2 or later with the `curl`, `json` and `sodium` extensions. No other dependencies.

## Install

```sh
composer require esuiss/relay
```

## Send a notification

```php
use Esuiss\Relay\Auth\ClientCredentials;
use Esuiss\Relay\Client;

$relay = new Client(
    'https://relay.example.com',
    new ClientCredentials('https://access.example.com', $clientId, $clientSecret),
);

$accepted = $relay->createEvent([
    'workflow' => 'welcome',
    'to' => [['id' => 'user-4821', 'email' => 'ayse@example.com']],
    'data' => ['first_name' => 'Ayşe'],
]);
```

Relay delivers at least once and, with durable idempotency, processes effectively once.

## Errors

Every problem answer becomes an `Esuiss\Relay\Exception\ApiException` subclass:
`AuthenticationException`, `ValidationException`, `NotFoundException`, `ConflictException`,
`RateLimitException`, `IdempotencyException` or `ServerException`. Each carries the status, the
error `code`, `retryable`, `requestId` and the full problem body.

```php
use Esuiss\Relay\Exception\ValidationException;

try {
    $relay->createEvent($event);
} catch (ValidationException $e) {
    error_log($e->errorCode . ' ' . json_encode($e->problem['errors'] ?? []));
}
```

## Pagination

List operations return a `Page`. Iterating it walks every following page, fetching each one only
when it is reached.

```php
foreach ($relay->listNotifications(limit: 100) as $notification) {
    echo $notification['id'], PHP_EOL;
}
```

## Verify webhooks

Verify the raw request body before parsing it. `whpk_` keys verify `v1a` (Ed25519) signatures,
`whsec_` secrets verify `v1` (HMAC-SHA-256) signatures; pass several keys during a rotation.

```php
use Esuiss\Relay\Exception\WebhookVerificationException;
use Esuiss\Relay\Webhook;

$webhook = new Webhook(['whpk_...']);

try {
    $event = $webhook->verifyAndDecode(file_get_contents('php://input'), getallheaders());
} catch (WebhookVerificationException) {
    http_response_code(400);
    exit;
}
```

Deduplicate by `webhook-id`: the same event can arrive more than once and in any order.

## Agents

```php
$opened = $relay->openWaitpoint($waitpoint);
$settled = $relay->awaitWaitpoint($opened->waitpoint['id'], timeout: 300.0);

$relay->consumeMailbox(function (array $record): void {
    handle($record);
}, max: 10);
```

`Esuiss\Relay\Stream::merge()` opens a stream first, then lists the history and drops what was
already seen by id and sequence.

## License

Apache-2.0
