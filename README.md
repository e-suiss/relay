# Relay

Relay is Suiss's notification, messaging and event orchestration platform. It answers one question: **how does this event or message reach the right person, service, device or AI agent?**

Relay decides who is notified, on which channel and when (workflows, routing, preferences, quiet hours, time zones); applies consent and regulatory rules (including Turkey's İYS, one-click unsubscribe and per-country rules); renders the message for each channel and language; delivers it through push, email, SMS, WhatsApp and other messaging apps, in-app inbox, webhooks and event destinations, with retries, fallback and provider failover; and records what happened with evidence — delivered, failed, unknown, or **why it was not sent**.

For AI agents, Relay adds waitpoints (wait for a human or system response), durable agent mailboxes, escalation chains and the A2A, MCP and AG-UI protocols. A delivery or a response is never treated as an authorization; approvals belong to [Access](https://github.com/e-suiss/access).

- **Overview (English):** [docs/overview.md](docs/overview.md)
- **Specification (Turkish, normative):** [docs/spec/](docs/spec/README.md)

## Status

Specification stage. The specification and the engineering conventions (§19.13) are defined; implementation has not started yet. The build order is in the feature inventory appendix of the specification.

## Technology

Elixir/OTP, PostgreSQL and Valkey. One application and one release; the `api`, `worker` and `socket` roles are selected at start-up. Relay runs on PostgreSQL and Valkey alone; everything else is optional.

## Repository layout

Described in the specification (§19.13.1, T-56): the Elixir application (`lib/`, `priv/`), SDKs (`sdks/`), the console and UI components (`web/`), provider simulators and contract tests (`conformance/`), load tests (`load/`), deployment files (`deploy/`) and documentation (`docs/`).

## License

Relay is fully open source under the [Apache License 2.0](LICENSE). Self-hosted and Suiss-hosted Relay run the same code; no feature is cloud-only.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Code, comments, commit messages and pull requests are written in English. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
