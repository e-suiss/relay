# First notification in 5 minutes

This guide takes you from a fresh checkout to a delivered notification and the decision record that explains it. Every command on this page runs in Relay's CI against a freshly built Relay, so what you see here works.

You need Docker, [`just`](https://github.com/casey/just), the Erlang and Elixir versions in `.tool-versions`, a Rust toolchain, SoftHSM and OpenSC, plus `curl`, `jq` and `uuidgen`.

## 1. Start Relay

```sh
git clone https://github.com/e-suiss/relay.git
cd relay
just dev
```

`just dev` starts the local services with the official Docker Compose file, creates a SoftHSM key store, builds the database and starts Relay. Relay serves its API over HTTPS only, so a Caddy reverse proxy with its own local certificate authority answers on `https://localhost:4443`, and `just dev` copies its root certificate to `deploy/tls/root.crt`. It also seeds what a new account gets:

- a tenant with its `default_timezone` and `default_locale`, and its `live` and `test` environments,
- a `test` API client with every server scope,
- a published sample workflow called `welcome`, with an inbox step and an email step,
- seven seed recipients that trigger common rules,
- the fake provider of the test plane, so no channel credentials are needed.

The test plane runs the same pipeline as `live`; only the last step, the provider call, is simulated. Rule ids and decisions are identical on both.

## 2. Get a token

Relay accepts Access client credentials tokens bound to a key with DPoP. Locally, a stand-in for Access signs them. Open a second terminal in the checkout and run:

<<< @/examples/curl/env.sh

`CA` is the local root certificate that `curl --cacert` and Node.js (`NODE_EXTRA_CA_CERTS`) trust. `TOKEN` is valid for an hour. Every request carries a fresh DPoP proof for its method and URL, which `dpop` prints. With an SDK you never handle either: it obtains, binds and refreshes tokens for you.

## 3. Send a notification

<<< @/examples/curl/first-notification.sh

The recipient is given in the request, with an `id` and an `email`. Relay creates the subscriber because the request carries contact details; a bare id that Relay does not know is refused with `recipient_not_found` rather than creating an empty profile.

Relay answers `202 Accepted` with one notification per recipient. Acceptance is not delivery: everything after this point is decided and recorded asynchronously.

## 4. See it in the test inbox

<<< @/examples/curl/test-inbox.sh

Every message sent on the test plane lands in the test inbox with what Relay decided and what it rendered. For each delivery you see the channel, the status, whether the policy gates `passed`, `stopped` or `deferred`, every decision recorded on the way and the rendered output, kept sealed for the test plane's retention. The console's test inbox shows the same thing. Security messages, such as one-time codes, are kept as a digest only.

## 5. Watch a rule decide

Every test plane comes with seven seed recipients set up to trigger the rules people ask about most: `seed_no_consent`, `seed_opted_out`, `seed_quiet_hours`, `seed_capped`, `seed_bounced`, `seed_no_device` and `seed_fallback_timezone`. Their addresses go to the fake provider. Send the welcome message to the one whose quiet hours cover the whole day:

<<< @/examples/curl/seed-quiet-hours.sh

Read the test inbox again: the email delivery is held, with the `rule_id` of the quiet hours rule and its one-sentence explanation. A decision is never an error, and a skipped or held message always tells you which rule did it. See [Why didn't they get it?](./decisions) for the full picture.

## 6. Do it from code

The same two calls with the TypeScript SDK:

<<< @/examples/typescript/send-event.ts#send

<<< @/examples/typescript/send-event.ts#decisions

SDKs add an `Idempotency-Key` to every write, retry only what Relay marks retryable and page lazily. See [SDKs](/sdks/) for every language.

## Next steps

- [Concepts](./concepts): tenants, subscribers, workflows, decisions and how they relate.
- [Guarantees and idempotency](./guarantees): what "accepted" promises.
- [Delivery semantics per channel](./delivery-semantics): what `sent` and `delivered` mean on each channel.
- [Webhooks](./webhooks): receive signed events about deliveries.
