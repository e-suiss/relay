# esuiss-relay

Python server SDK for Relay, the Suiss notification, messaging and event orchestration API.

- Typed operations for the whole server API, generated from the OpenAPI contract
- Access client credentials with DPoP-bound tokens, handled for you
- Automatic `Idempotency-Key` on every mutating call, kept across retries
- Retries only for errors marked `retryable`, with exponential backoff, full jitter and `Retry-After`
- Typed errors: authentication, validation, rate limit and quota, idempotency, server
- Lazy pagination, webhook verification over the raw body, agent helpers

Relay delivers at least once; with durable idempotency, processing is effectively once.

## Install

```sh
pip install esuiss-relay
```

Python 3.11 or later.

## Send a notification

```python
from esuiss_relay import ClientCredentials, Relay

relay = Relay(
    "https://relay.example.com",
    ClientCredentials("https://access.example.com", "client_id", "client_secret"),
)

accepted = relay.create_event(
    {"workflow": "welcome", "to": [{"id": "user-4821", "email": "ayse@example.com"}]}
)
```

Every request carries the API version the SDK is pinned to (`esuiss_relay.API_VERSION`); a package
update never changes the version it speaks.

## Lists

List operations return a page; iterating it fetches later pages only when needed.

```python
for notification in relay.list_notifications(limit=100):
    print(notification["id"])
```

## Errors

```python
from esuiss_relay import RateLimitError, ValidationError

try:
    relay.create_event({"workflow": "welcome", "to": []})
except ValidationError as error:
    print(error.code, error.problem.get("errors"))
except RateLimitError as error:
    print(error.retry_after)
```

## Webhooks

Verify the raw request body before parsing it.

```python
from esuiss_relay import Webhook, WebhookVerificationError

webhook = Webhook("whpk_...")
try:
    event = webhook.verify_event(raw_body, request_headers)
except WebhookVerificationError:
    ...
```

## Agents

```python
waitpoint = relay.create_and_await_waitpoint(spec, timeout=600)
lease = relay.mailbox_lease(10)
relay.mailbox_ack(lease["lease_id"], [record["id"] for record in lease["records"]])
```

## License

Apache-2.0
