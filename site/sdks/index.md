# SDKs

Every SDK is generated from Relay's OpenAPI contract with a pinned generator, with a thin hand-written layer on top, and tested against the same language-neutral conformance vectors. Each release is pinned to one dated API version, so updating a package never changes the API behaviour you get.

## Server SDKs

For your backend. They authenticate with your Access API client and DPoP-bound tokens.

| Language               | Package                  | Guide                      |
| ---------------------- | ------------------------ | -------------------------- |
| TypeScript and Node.js | `@esuiss/relay`          | [TypeScript](./typescript) |
| Go                     | `github.com/e-suiss/relay/sdks/go` | [Go](./go)       |
| .NET                   | `Esuiss.Relay`           | [.NET](./dotnet)           |
| Java                   | `app.suiss:esuiss-relay` | [Java](./java)             |
| Elixir                 | `esuiss_relay`           | [Elixir](./elixir)         |

Every server SDK:

- adds an `Idempotency-Key` to every write and keeps it the same on every retry,
- retries only errors Relay marks `retryable`, with exponential backoff, full jitter and `Retry-After`,
- raises typed errors for authentication, validation, rate limits and quota, idempotency and server failures,
- pages lazily through lists,
- verifies webhooks over the raw body (Ed25519 `v1a` and HMAC `v1`),
- ships helpers for waitpoints and the agent mailbox, including the follow pattern.

## Client SDKs

For apps on your users' devices. They hold only a short-lived, narrow-scope subscriber token that your backend obtains; they never send events, never write a subscriber's profile or consents and never hold a secret.

| Platform     | Package                          | Guide                              |
| ------------ | -------------------------------- | ---------------------------------- |
| Web browser  | `@esuiss/relay/browser`          | [TypeScript](./typescript#browser) |
| iOS          | `EsuissRelay` (Swift package)    | [iOS](./swift)                     |
| Android      | `app.suiss:esuiss-relay-android` | [Android](./kotlin)                |
| React Native | `@esuiss/relay-react-native`     | [React Native](./react-native)     |
| Flutter      | `esuiss_relay`                   | [Flutter](./flutter)               |

Client SDKs register push devices, report displayed and clicked receipts, keep the inbox in sync over WebSocket with Server-Sent Events and long-polling as fallbacks, queue changes made offline, and include ready-made inbox and preference components with theming, Turkish and English texts and WCAG 2.2 AA accessibility.

## Every snippet is tested

The code on these pages is compiled in CI against the SDK in the same commit. TypeScript snippets also run against a freshly built Relay.
