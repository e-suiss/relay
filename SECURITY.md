# Security Policy

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub's private vulnerability reporting:
**Security → Report a vulnerability** on this repository.

Do not open a public issue, pull request or discussion for a suspected vulnerability.

Please include:
- a description of the issue and its impact,
- steps to reproduce or a proof of concept,
- affected versions or components, if known.

## What to expect

- We acknowledge reports and keep you informed while we investigate.
- We follow coordinated vulnerability disclosure with a default embargo of 90 days, shortened when a vulnerability is actively exploited.
- Fixes are always released in the open-source version; security fixes are never limited to a paid offering.
- Advisories are published as GitHub Security Advisories, and reporters are credited unless they ask otherwise.

## Scope

No release has been published yet. Reports about the code on `main` and about the security design are welcome through the same private channel.

## Known platform limitations

Relay runs on Erlang/OTP. Operators should know three properties of that platform:

- **TLS throughput.** The Erlang TLS implementation is slower than native TLS stacks under bulk load. Terminate inbound TLS at a load balancer or reverse proxy; outbound certificate verification is always on and cannot be disabled.
- **Secrets in memory.** The runtime cannot guarantee that a secret is wiped from memory. Long-lived signing keys therefore never enter application memory: signing and key unwrapping happen in an HSM through PKCS#11. Crash dumps are disabled in releases.
- **No FIPS mode.** Relay does not offer a FIPS 140 validated build.

