# Contributing to Relay

Thank you for your interest in Relay. This guide explains how to set up a development environment, the rules code must follow, and how changes get merged.

The project foundation is in place and product features are being built. The rules below are binding and enforced in CI.

## Reporting security issues

Do **not** open a public issue for a vulnerability. Follow [`SECURITY.md`](SECURITY.md).

## Development environment

You need Docker, `just` and the Erlang/Elixir versions in `.tool-versions` (`mise install`). Getting started takes three steps:

```sh
git clone https://github.com/e-suiss/relay.git
cd relay
just dev    # starts PostgreSQL, Valkey, Mailpit, APNs/FCM/SMS simulators, tracing and metrics
just test   # runs the same tests as CI on pull requests
```

Other commands: `just check` (the same checks as CI on a pull request), `just chaos` (adds Toxiproxy for fault injection) and `just bench` (wall-clock benchmarks).

There is no "development mode": compliance and security checks are never disabled locally. Local equivalents replace production services instead (T-57).

## Code rules (summary)

The full rules are in the project specification (§19.13, T-56…T-68).

- Code, comments, commit messages and pull requests are in English.
- `mix format` applies; the build runs with `--warnings-as-errors`; Credo (strict), Dialyzer and Sobelow run in CI.
- Decision code is pure; side effects live at the edges behind behaviours. Time and randomness come only from injected ports, never `DateTime.utc_now/0` or `:rand` directly.
- A record, its queue job and its outbox event are written in one transaction; external calls never happen inside a transaction.
- A "not sent" decision is a result (`{:skip, reason, rule_id}`), not an error.
- Secrets, contact addresses and message content are never logged; they use self-redacting types.
- SQL and `Repo` calls live only in each context's store modules. There are no physical deletes (`DELETE`/`TRUNCATE`).
- Code carries no explanatory comments. Code that implements a specification rule names its ID on a bare comment line, e.g. `# INV-12`; the reasoning lives in the specification. Allowed otherwise: `@moduledoc`/`@doc`, tool directives, `TODO(#n):`, and `// SAFETY:` in Rust.
- New dependencies and tool versions must have been released at least seven days earlier. GitHub Actions are pinned by commit SHA, container images by digest.
- `TODO` comments must reference an issue.
- Tests are named after behavior; flaky tests are quarantined, never retried until green.

## Commits and changes

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/), with the context or area as scope: `feat(channels): add HMS push adapter`.
- Commits must be signed. `main` has a linear history; force pushes are not allowed.
- External contributions come as pull requests, are kept small and are merged with squash merge after CI passes.
- Changes that add or change a specification decision carry the `decision` label and update the decision register (T-66).

## Code of conduct

Participation in this project is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
