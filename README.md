# Relay

**Open-source notification, messaging and event delivery — for people, services, devices and AI agents.**

Relay takes an event from your product and gets it to the right recipient, on the right channel, at the right time — with consent rules applied, retries and fallback handled, and a record of what happened. When a message is *not* sent, Relay tells you why.

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Status: pre-alpha](https://img.shields.io/badge/status-pre--alpha-orange.svg)

---

## Why Relay

Every product ends up rebuilding the same notification plumbing: channel selection, retries, provider failover, preference centers, quiet hours, consent registries, delivery tracking, in-app inboxes and webhooks. And AI agents add a new need: asking a human a question, waiting for the answer, and escalating when nobody responds.

Relay does all of that in one place, on infrastructure you already know: **PostgreSQL and Valkey**. Nothing else is required.

## Features

**Channels**
- Push (APNs, FCM, Web Push, HMS), email (ESPs or your own SMTP server), SMS, voice
- WhatsApp, Slack, Microsoft Teams, Telegram
- In-app inbox with real-time updates (WebSocket and SSE)
- Webhooks and event destinations: HTTPS, Kafka, NATS, RabbitMQ, SQS, SNS, EventBridge, Pub/Sub, Service Bus, S3

**Orchestration**
- Workflows built in a visual editor, as YAML/JSON files in git, or with an SDK — all the same format
- Routing policies with fallback, fan-out and last-active device; escalate-unless-seen
- Digest, throttle, deduplication, scheduling, recurring notifications, A/B tests
- Topics and subscriptions; multi-tenant with sub-tenants (per-customer branding and senders)

**Reliability**
- Idempotent API, at-least-once delivery with deduplication
- Provider error classification, circuit breakers, active-passive or cost-based provider routing
- Four-axis delivery state from an append-only ledger; honest `unknown` when a provider stays silent
- Kill switch, per-tenant fairness, priority lanes that keep OTP traffic moving

**Consent and compliance**
- Message classes (security, transactional, marketing, …) that drive the rules
- Preference center: category × channel, per-workflow opt-out, mute, quiet hours
- Turkey's İYS consent registry built in; one-click unsubscribe (RFC 8058); per-country rules for TR, EU and US
- No physical deletes; personal data erasure by crypto-shredding

**For AI agents**
- Waitpoints: ask a human or a system, wait durably, never lose an early reply
- Durable agent mailboxes with lease/ack; built-in escalation chains
- A2A, MCP and AG-UI support
- Messages to agents are structured data, never instructions; replies are never treated as authorization

## How it works

```text
 event ──► accept ──► decide ──────────────► render ──► deliver ──► record
          (idempotent) (class, consent,       (template,  (channel,   (ledger,
                        preferences, quiet     language,   provider,   state, why
                        hours, route)          branding)   fallback)   not sent)
```

One Elixir application, one release. Run it as a single process, or scale the `api`, `worker` and `socket` roles separately.

## Getting started

Relay is in active design; implementation has not started yet. When the first build lands, local development will be one command:

```sh
git clone https://github.com/e-suiss/relay.git
cd relay
just dev    # PostgreSQL, Valkey, Mailpit, push and SMS simulators
just test
```

SDKs are planned for TypeScript/Node, Python, Go, Java, .NET, Elixir, PHP and Ruby, plus iOS, Android, React Native and Flutter, with ready-made inbox, toast and preference components (React and web components).

## Tech stack

Elixir/OTP, Phoenix, PostgreSQL, Valkey, Oban (open source), React for the console and UI components.

## Related projects

- **[Access](https://github.com/e-suiss/access)** — identity and authority. Relay and Access run independently and work together without extra setup: Access sends its messages through Relay, and Relay uses Access for sign-in and approvals.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request, and report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

Relay is open source under the [Apache License 2.0](LICENSE). Self-hosted and Suiss-hosted Relay run the same code; no feature is cloud-only.
