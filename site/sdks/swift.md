# iOS (Swift)

The `EsuissRelay` Swift package is for apps that talk to Relay as a subscriber: push device registration, content-free push, the inbox with realtime updates and an offline queue, the preference centre and SwiftUI components. iOS 16 or later.

```swift install
.package(url: "https://github.com/e-suiss/relay-swift", from: "1.0.0")
```

| Product                          | Contents                                       |
| -------------------------------- | ---------------------------------------------- |
| `EsuissRelay`                    | The client: push, inbox, realtime, preferences |
| `EsuissRelayUI`                  | SwiftUI inbox and preference centre            |
| `EsuissRelayNotificationService` | The Notification Service Extension helper      |

The SDK works only with a narrow-scope subscriber token that your app obtains from your backend. It never holds Access tokens or other secrets, never triggers events and never writes the subscriber's identity, contact data or consents.

## Create the client

<<< @/examples/swift/DocsExamples.swift#client

## Register for push

Call this on every launch and whenever APNs hands out a token. The permission state is reported with it. Provisional authorization is used only when every message class you start with is `marketing` or `social` (`RelayPermissionMapping.authorizationOptions(for:)`).

<<< @/examples/swift/DocsExamples.swift#push

## Show the inbox

<<< @/examples/swift/DocsExamples.swift#inbox

`RelayNotificationCenterDelegate` records displayed and clicked receipts and opens the preference centre when the user taps your app's notification settings in iOS Settings.

## Content-free push

Subclass `RelayNotificationService` in your Notification Service Extension. It fetches the content over TLS; when it cannot, the generic text stays on the lock screen.

## Behaviour

- Only retryable errors are retried, with full-jitter backoff and `Retry-After`; every write carries an idempotency key.
- Realtime tries WebSocket, then Server-Sent Events, then long-polling, and reconnects with full jitter between 1 and 60 seconds.
- In the background the connection closes; on return the SDK refreshes the counters, reconnects, syncs and drains the offline queue last.
