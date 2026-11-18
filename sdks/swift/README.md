# EsuissRelay for iOS

Swift package for apps that talk to Relay as a subscriber: push device registration, content-free
push handling, the inbox with realtime updates and an offline intent queue, the preference centre,
and SwiftUI components.

The SDK only works with a narrow-scope subscriber token that your app obtains and hands over through
`RelayTokenProvider`. It never holds Access tokens or other secrets, never triggers events and never
writes the subscriber's identity, contact data or consents.

## Install

```swift
.package(url: "https://github.com/e-suiss/relay-swift", from: "1.0.0")
```

Products: `EsuissRelay` (core), `EsuissRelayUI` (SwiftUI inbox and preference centre),
`EsuissRelayNotificationService` (Notification Service Extension helper). iOS 16 or later.

## Quick start

```swift
import EsuissRelay
import EsuissRelayUI

struct Tokens: RelayTokenProvider {
  func subscriberToken(forceRefresh: Bool) async throws -> RelaySubscriberToken {
    try await MyBackend.relaySubscriberToken(refresh: forceRefresh)
  }
}

let client = RelayClient(
  configuration: RelayConfiguration(
    baseURL: URL(string: "https://relay.example.com")!,
    appIdentifier: Bundle.main.bundleIdentifier!,
    tokenProvider: Tokens()
  )
)
let observer = RelayLifecycleObserver(lifecycle: client.lifecycle)

// On every launch and whenever APNs hands out a token.
try await client.push.register(apnsToken: deviceToken, environment: .production)
```

Ask for permission with the classes you send; provisional authorization is used only when every class
is `marketing` or `social`:

```swift
let options = RelayPermissionMapping.authorizationOptions(for: [.transactional, .marketing])
try await UNUserNotificationCenter.current().requestAuthorization(options: options)
```

Show the inbox and the preference centre:

```swift
NavigationStack { RelayInboxView(store: client.store) }
  .relayTheme(RelayTheme(accent: .indigo))
  .relayPreferencesSheet(router: router, model: RelayPreferencesModel(api: client.preferences))
```

`RelayNotificationCenterDelegate` records displayed and clicked receipts and opens the preference
centre when the user taps the app's notification settings in iOS Settings.

## Content-free push

Subclass `RelayNotificationService` in your Notification Service Extension and return a push API that
shares the app's device storage (an App Group suite). The extension fetches the content over TLS; when
it cannot, the generic text stays on the lock screen.

## Behaviour

- Requests carry the pinned API version and a random idempotency key on every mutation; only
  retryable errors are retried, with full-jitter backoff and `Retry-After` honoured.
- Realtime tries WebSocket, then Server-Sent Events, then long-poll, and reconnects with full jitter
  between 1 and 60 seconds.
- In the background the connection closes; in the foreground the SDK refreshes the counters,
  reconnects, syncs, and drains the offline queue last.
- Device status signals are sent with a time to live and are never logged.

## Development

The models in `Sources/EsuissRelayAPI` are generated from the subscriber OpenAPI contract by a pinned
`swift-openapi-generator`; run `regenerate.sh` and commit the result. CI regenerates and fails on
any difference.

Licensed under Apache-2.0.
