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

The preference centre also lists the subscriber's commercial consents read-only. Pass
`consentManagementURL` to `RelayPreferencesModel` to show a link to the page where your account
system changes them; without it no link is shown.

Inbox items written by an AI agent carry an agent label. An item that asks for a response shows its
options as buttons while the response is awaited, then whether it is being processed, who answered
and when, or that no answer is awaited any more. Approval requests only link to the approval page and
are never answered in the app.

## Content-free push

Subclass `RelayNotificationService` in your Notification Service Extension and return a push API that
shares the app's device storage (an App Group suite). The extension fetches the content by the
delivery id the push carries, over TLS; when it cannot, the generic text stays on the lock screen.

Registration reports the Critical Alerts and Time Sensitive permissions the device knows, so a
notification the device cannot take at its level is delivered one level lower.

## Duplicate notification telemetry

Turn on `reportDisplayedNotifications` to help Relay measure how often the same notification is
shown twice, for example while traffic moves over from another system:

```swift
let configuration = RelayConfiguration(
  baseURL: URL(string: "https://relay.example.com")!,
  appIdentifier: Bundle.main.bundleIdentifier!,
  tokenProvider: Tokens(),
  reportDisplayedNotifications: true
)
```

It is off by default. When it is on, every Relay push shown in the foreground through
`RelayNotificationCenterDelegate` is queued, and your app can queue a notification it displayed
itself with `await client.reportDisplayed(notificationId:)`. Only the SHA-256 digest of the
identifier and the time it was shown leave the device, never the identifier or the content. The
queue is sent in batches of up to 100 when 20 notifications are waiting, 30 seconds after the first
one and when the app goes to the background; a failed batch is retried with the same idempotency key
and dropped after 24 hours. The token needs the `devices:write` scope.

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
