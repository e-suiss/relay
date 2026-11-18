# Elixir

`esuiss_relay` is the server SDK for Elixir 1.18 or later, with no runtime dependencies: HTTP runs on `:httpc`, JSON on Elixir's `JSON` and signatures on `:crypto`.

```elixir install
def deps do
  [{:esuiss_relay, "~> 0.1"}]
end
```

## Send an event

Give the client your Access API client and Relay's Access client id (`access_client_id` in Relay's discovery document); the SDK obtains, binds and caches the tokens.

<<< @/examples/elixir/quickstart.ex#quickstart{elixir}

Every operation of the [server API](/reference/api/server/) is a function of `EsuissRelay.Api`: path parameters first, then the body when the operation takes one, then a keyword list of query parameters and request options (`:idempotency_key`, `:if_match`, `:max_retries`, `:timeout` and others).

## Page through lists

<<< @/examples/elixir/quickstart.ex#decisions{elixir}

A page is an `Enumerable` over the whole list; the next page is requested only when the items already read are used up.

## Errors

<<< @/examples/elixir/quickstart.ex#errors{elixir}

Every function returns `{:ok, result}` or `{:error, error}`. Errors carry Relay's problem details: `code`, `title`, `detail`, `request_id`, `retryable` and `retry_after`.

## Verify webhooks

<<< @/examples/elixir/webhooks.ex#verify{elixir}

Keys are `whpk_…` (Ed25519) or `whsec_…` (HMAC); pass every key of a rotation overlap.

## Agents

`EsuissRelay.Agents` has `create_waitpoint/2`, `await_waitpoint/3`, `lease/2`, `ack/3` and `follow/4`, which opens your hint stream first, reads what the mailbox holds, reads again on every hint and hands each record to your function once.
