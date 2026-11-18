# esuiss_relay

Elixir server SDK for [Relay](https://github.com/e-suiss/relay), the notification, messaging and agent platform of Suiss.

- One function for every operation of the Relay server API, generated from the OpenAPI contract
- Automatic `Idempotency-Key`, the same on every retry of a call
- Retries only for errors Relay marks `retryable`, honouring `Retry-After`, otherwise exponential backoff with full jitter
- Typed errors: authentication, validation, rate limit and quota, idempotency, server
- Lazy cursor pagination: a page is an `Enumerable` over the whole list
- Raw body webhook verification (Ed25519 `v1a` and HMAC `v1`)
- Agent helpers: waitpoints, the durable mailbox and the follow pattern
- Pinned to one API version: upgrading the package never changes the behaviour of the API you call

No runtime dependencies: HTTP runs on `:httpc`, JSON on Elixir's `JSON`, signatures on `:crypto`.

## Installation

```elixir
def deps do
  [{:esuiss_relay, "~> 0.1"}]
end
```

Requires Elixir 1.18 or later.

## Quick start

Relay accepts DPoP-bound Access tokens. Give the client your Access API client and Relay's Access client id (`access_client_id` in Relay's discovery document); the SDK obtains, binds and caches the tokens.

```elixir
credentials =
  EsuissRelay.Credentials.AccessClient.new(
    token_endpoint: "https://access.example.com/oauth2/token",
    client_id: System.fetch_env!("ACCESS_CLIENT_ID"),
    client_secret: System.fetch_env!("ACCESS_CLIENT_SECRET"),
    resource: System.fetch_env!("RELAY_ACCESS_CLIENT_ID")
  )

client = EsuissRelay.new(base_url: "https://relay.example.com", credentials: credentials)

{:ok, event} =
  EsuissRelay.Api.create_event(client, %{
    "workflow" => "order-shipped",
    "to" => ["user-4821"],
    "data" => %{"order" => "4821"}
  })
```

A token obtained elsewhere works too: `EsuissRelay.Credentials.Static.new(token, dpop_key)`.

## Requests

Path parameters come first, then the body when the operation requires one, then options. Query parameters and request options share the keyword list:

```elixir
EsuissRelay.Api.get_notification(client, "ntf_...", expand: ["deliveries"])

EsuissRelay.Api.update_subscriber(client, "sub_...", %{"locale" => "tr-TR"}, if_match: etag)

EsuissRelay.Api.create_waitpoint(client, body, idempotency_key: "order-4821-review")
```

Request options: `:idempotency_key`, `:if_match`, `:beta`, `:headers`, `:content_type`, `:max_retries`, `:timeout` and `:body` for operations whose body is optional.

## Errors and retries

Every function returns `{:ok, result}` or `{:error, error}`:

```elixir
case EsuissRelay.Api.create_event(client, event) do
  {:ok, accepted} -> accepted
  {:error, %EsuissRelay.ValidationError{problem: problem}} -> {:invalid, problem["errors"]}
  {:error, %EsuissRelay.QuotaError{}} -> :quota_exhausted
  {:error, error} -> raise error
end
```

| Error | When |
|---|---|
| `EsuissRelay.AuthenticationError` | credentials missing, refused or without the scope |
| `EsuissRelay.ValidationError` | 400, 413, 415, 422 |
| `EsuissRelay.RateLimitError` / `EsuissRelay.QuotaError` | 429 `rate_limited` / `quota_exhausted` |
| `EsuissRelay.IdempotencyError` | key missing, invalid, reused or in progress |
| `EsuissRelay.ServerError` | 5xx |
| `EsuissRelay.NotFoundError`, `EsuissRelay.ConflictError`, `EsuissRelay.ApiError` | 404; 409, 412, 428; anything else |
| `EsuissRelay.ConnectionError` | no answer arrived |

Errors carry the problem details Relay returned: `code`, `title`, `detail`, `request_id`, `retryable` and `retry_after`, and a `category` shared by every Relay SDK: `:auth`, `:validation`, `:rate_limit`, `:idempotency` or `:server` (`:connection` when no answer arrived). The client retries an error only when it is retryable, at most `:max_retries` times (default 3), waiting for `Retry-After` (seconds or an HTTP date, at most 60 seconds) or else a random delay under an exponential ceiling of 0.5 to 8 seconds.

Pass `raw: true` to get an `EsuissRelay.Response` with the status, the headers and `replayed`, which is true when Relay answered with the stored response of an earlier request with the same idempotency key.

## Pagination

```elixir
{:ok, page} = EsuissRelay.Api.list_waitpoints(client, state: "open", limit: 100)

page
|> Stream.filter(&(&1["kind"] == "review"))
|> Enum.take(10)
```

The next page is requested only when the items already read are used up.

## Webhooks

Verify over the raw body, exactly as the bytes arrived:

```elixir
case EsuissRelay.Webhook.verify(conn.req_headers, raw_body, ["whpk_..."]) do
  {:ok, %{id: id}} -> handle_once(id, raw_body)
  {:error, _reason} -> send_resp(conn, 400, "")
end
```

Keys are `whpk_...` (Ed25519) or `whsec_...` (HMAC secret); pass every key of a rotation overlap. The tolerance is 300 seconds by default. Relay delivers at least once: keep `webhook-id` for at least 96 hours and drop repeats.

## Agents

```elixir
{:ok, waitpoint} = EsuissRelay.Agents.create_waitpoint(client, body)
{:ok, resolved} = EsuissRelay.Agents.await_waitpoint(client, waitpoint["id"], timeout: 600_000)

{:ok, lease} = EsuissRelay.Agents.lease(client, 10)
ids = Enum.map(lease["records"], & &1["id"])
{:ok, _ack} = EsuissRelay.Agents.ack(client, lease["lease_id"], ids)
```

`EsuissRelay.Agents.follow/4` opens your hint stream first, then reads what the mailbox already holds, then reads again on every hint, and hands each record to your function once by its id:

```elixir
EsuissRelay.Agents.follow(client, fn -> subscribe_to_hints() end, &process_record/1)
```

## Development

The API layer in `lib/esuiss_relay/generated` is generated from the contracts in this repository:

```sh
mix esuiss_relay.gen
mix format
```

CI regenerates it and fails when the committed code differs.

## License

Apache-2.0
