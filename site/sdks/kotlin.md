# Android (Kotlin)

The Android library is for apps that talk to Relay as a subscriber: push device registration, data messages for content-free push, notification channels per category and interruption level, the inbox with realtime updates and an offline queue, the preference centre and Jetpack Compose components. Android 8.0 (API 26) or later.

```kotlin install
implementation("app.suiss:esuiss-relay-android:1.0.0")
```

The SDK works only with a narrow-scope subscriber token that your app obtains and hands over through `RelayTokenProvider`. It never holds Access tokens or other secrets, never triggers events and never writes the subscriber's identity, contact data or consents.

## Create the client

<<< @/examples/kotlin/DocsExamples.kt#client

Create the notification channels once with `RelayNotificationChannels.create`. Channel ids are `relay.<category>.<level>` and never change between releases.

## Push

From your messaging service:

<<< @/examples/kotlin/DocsExamples.kt#push

Registration reports the notification permission and each channel's importance on every launch. When the content of a content-free push cannot be fetched, a generic text is shown instead.

## Show the inbox

<<< @/examples/kotlin/DocsExamples.kt#inbox

## Behaviour

- Only retryable errors are retried, with full-jitter backoff and `Retry-After`; every write carries an idempotency key.
- Realtime tries WebSocket, then Server-Sent Events, then long-polling, and reconnects with full jitter between 1 and 60 seconds.
- In the background the connection closes; on return the SDK refreshes the counters, reconnects, syncs and drains the offline queue last.
- Device status signals are sent with a time to live and are never logged.
