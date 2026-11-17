# esuiss-relay

Ruby server SDK for Relay. Every operation of the Relay server API is a method on
`Esuiss::Relay::Client`, generated from the OpenAPI contract, with a thin hand-written layer on top.

- DPoP-bound Access tokens obtained with client credentials, a fresh proof on every request
- An `Idempotency-Key` on every mutating call, the same key on every retry
- Retries only for problems marked `retryable`, with exponential backoff, full jitter and `Retry-After`
- Typed errors: `AuthenticationError`, `ValidationError`, `NotFoundError`, `ConflictError`,
  `RateLimitError`, `IdempotencyError`, `ServerError`
- Lazy pagination: a list result is an `Enumerable` that fetches the next page only when needed
- Webhook verification over the raw body (Ed25519 `v1a` and HMAC `v1`)
- Agent helpers for waitpoints, the durable mailbox and the stream-then-history pattern

The SDK is pinned to one API version (`Esuiss::Relay::API_VERSION`) and sends it as
`Relay-Version` on every request; upgrading the gem never changes the version it speaks.
It needs Ruby 3.2 or later and has no runtime dependencies.

## Install

```ruby
gem "esuiss-relay"
```

## Send a notification

```ruby
require "esuiss/relay"

auth = Esuiss::Relay::ClientCredentials.new(
  issuer: "https://access.example.com/r/main",
  client_id: ENV.fetch("RELAY_CLIENT_ID"),
  client_secret: ENV.fetch("RELAY_CLIENT_SECRET")
)
relay = Esuiss::Relay::Client.new(base_url: "https://relay.example.com", auth: auth)

relay.create_event({ "workflow" => "welcome", "to" => [{ "id" => "user-4821", "email" => "ayse@example.com" }] })
```

## Pagination

```ruby
relay.list_notifications(limit: 50, workflow: "welcome").each do |notification|
  puts notification["id"]
end
```

## Errors

```ruby
begin
  relay.get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
rescue Esuiss::Relay::NotFoundError => e
  puts e.code
rescue Esuiss::Relay::APIError => e
  puts "#{e.status} #{e.code} #{e.request_id}"
end
```

## Webhooks

```ruby
webhook = Esuiss::Relay::Webhook.new([ENV.fetch("RELAY_WEBHOOK_PUBLIC_KEY")])
event = webhook.construct_event(request.raw_post, request.headers)
```

Pass the raw request body, before any JSON parsing. Deduplicate by `webhook-id`: delivery is at
least once.

## Agents

```ruby
handle = relay.open_waitpoint(waitpoint_body)
result = relay.await_waitpoint(handle.id, timeout: 600)

relay.consume_mailbox(max: 10) { |record| handle_record(record) }
```

## Development

The generated code lives in `lib/esuiss/relay/generated` and is rebuilt from the contract with
`ruby codegen/generate.rb`; CI fails when it differs.
