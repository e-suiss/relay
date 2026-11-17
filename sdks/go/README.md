# Relay Go SDK

Go client for the Relay server API.

```sh
go get github.com/e-suiss/relay/sdks/go
```

```go
import relay "github.com/e-suiss/relay/sdks/go"

auth, err := relay.NewClientCredentials("https://access.example.com", clientID, clientSecret,
	relay.WithScope("publish read"))
if err != nil {
	return err
}
client, err := relay.NewClient("https://relay.example.com", auth)
if err != nil {
	return err
}

for notification, err := range client.ListNotificationsIter(ctx, nil) {
	if err != nil {
		return err
	}
	fmt.Println(notification.ID)
}
```

- Every operation of the server API is a method on `Client`, generated from the OpenAPI contract
  (`go run ./internal/codegen` in `internal/codegen` regenerates `*_gen.go`).
- Requests carry a DPoP-bound Access token with a fresh proof per attempt and are pinned to
  `relay.APIVersion` through `Relay-Version`.
- Mutating requests get an `Idempotency-Key` (or `relay.WithIdempotencyKey`) that stays the same
  on every retry. Only problems marked `retryable: true` are retried, with exponential backoff,
  full jitter and `Retry-After`.
- Errors are typed: `*relay.AuthenticationError`, `*relay.ValidationError`,
  `*relay.NotFoundError`, `*relay.ConflictError`, `*relay.RateLimitError`,
  `*relay.IdempotencyError`, `*relay.ServerError`; each unwraps to `*relay.APIError`.
- List operations return a `*relay.Page[T]`; the `...Iter` methods walk every page lazily.
- `relay.NewWebhookVerifier` checks webhook signatures (v1a Ed25519, v1 HMAC) over the raw body.
- Agent helpers: `OpenWaitpoint`, `AwaitWaitpoint`, `ReadMailbox`, `LeaseMailbox`, `AckMailbox`,
  `MergeMailbox` and `MergeStreamAndHistory`.

Relay delivers at least once; with durable idempotency, processing is effectively once.

## License

Apache-2.0
