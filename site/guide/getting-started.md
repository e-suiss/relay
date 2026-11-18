# First notification in 5 minutes

This guide takes you from a fresh checkout to a delivered notification and the decision record that explains it. Every command on this page runs in Relay's CI against a freshly built Relay, so what you see here works.

You need Docker, [`just`](https://github.com/casey/just), the Erlang and Elixir versions in `.tool-versions`, a Rust toolchain, SoftHSM and OpenSC, plus `curl`, `jq` and `uuidgen`.

## 1. Start Relay

```sh
git clone https://github.com/e-suiss/relay.git
cd relay
just dev
```

`just dev` starts the local services with the official Docker Compose file, creates a SoftHSM key store, builds the database and starts Relay on `http://localhost:4000`. It also seeds what a new account gets:

- a tenant with its `default_timezone` and `default_locale`, and its `live` and `test` environments,
- a `test` API client with every server scope,
- a published sample workflow called `welcome`,
- the fake provider of the test plane, so no channel credentials are needed.

The test plane runs the same pipeline as `live`; only the last step, the provider call, is simulated. Rule ids and decisions are identical on both.

## 2. Get a token

Relay accepts Access client credentials tokens bound to a key with DPoP. Locally, a stand-in for Access signs them. Open a second terminal in the checkout and run:

<<< @/examples/curl/env.sh

`TOKEN` is valid for an hour. Every request carries a fresh DPoP proof for its method and URL, which `dpop` prints. With an SDK you never handle either: it obtains, binds and refreshes tokens for you.

## 3. Send a notification

<<< @/examples/curl/first-notification.sh

The recipient is given in the request, with an `id` and an `email`. Relay creates the subscriber because the request carries contact details; a bare id that Relay does not know is refused with `recipient_not_found` rather than creating an empty profile.

Relay answers `202 Accepted` with one notification per recipient. Acceptance is not delivery: everything after this point is decided and recorded asynchronously.

## 4. See what happened

<<< @/examples/curl/decisions.sh

Each item is one notification with its deliveries. For every delivery you see the channel, the status, whether the policy gates `passed`, `stopped` or `deferred`, and every decision recorded on the way. A decision carries a `rule_id` and a one-sentence explanation in English and Turkish, so a skipped message always tells you which rule skipped it and why.

Try sending at night in the subscriber's time zone, or after opting the subscriber out, and read the decisions again: the delivery is `skipped` with the rule that stopped it. See [Why didn't they get it?](./decisions) for the full picture.

## 5. Do it from code

The same two calls with the TypeScript SDK:

<<< @/examples/typescript/send-event.ts#send

<<< @/examples/typescript/send-event.ts#decisions

SDKs add an `Idempotency-Key` to every write, retry only what Relay marks retryable and page lazily. See [SDKs](/sdks/) for every language.

## Next steps

- [Concepts](./concepts): tenants, subscribers, workflows, decisions and how they relate.
- [Guarantees and idempotency](./guarantees): what "accepted" promises.
- [Delivery semantics per channel](./delivery-semantics): what `sent` and `delivered` mean on each channel.
- [Webhooks](./webhooks): receive signed events about deliveries.
