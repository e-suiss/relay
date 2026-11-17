# esuiss-relay-android

Android library for apps that talk to Relay as a subscriber: push device registration, data-message
handling for content-free push, notification channels per category and interruption level, the inbox
with realtime updates and an offline intent queue, the preference centre, and Jetpack Compose
components.

The SDK only works with a narrow-scope subscriber token that your app obtains and hands over through
`RelayTokenProvider`. It never holds Access tokens or other secrets, never triggers events and never
writes the subscriber's identity, contact data or consents.

## Install

```kotlin
dependencies {
    implementation("app.suiss:esuiss-relay-android:1.0.0")
}
```

Android 8.0 (API 26) or later.

## Quick start

```kotlin
val client =
    RelayClient(
        configuration =
            RelayConfiguration(
                baseUrl = "https://relay.example.com",
                appIdentifier = context.packageName,
                tokenProvider = { refresh -> myBackend.relaySubscriberToken(refresh) },
            ),
        context = context,
        smallIcon = R.drawable.ic_notification,
    )
client.lifecycle.observeProcess(client.scope)

RelayNotificationChannels.create(context, categories, levelNames = { level -> getString(levelName(level)) })
```

From your messaging service:

```kotlin
override fun onNewToken(token: String) {
    scope.launch { client.push.register(token) }
}

override fun onMessageReceived(message: RemoteMessage) {
    scope.launch { client.messaging.handle(message.data) }
}
```

Channel ids are `relay.<category>.<level>` and never change between releases. Registration reports the
notification permission and each channel's current importance on every launch; the DND access status
for `critical` channels is available from `SystemNotificationSettingsReader`.

Compose:

```kotlin
RelayThemeProvider(RelayTheme(accent = brandColor)) {
    RelayInbox(client.store)
}
```

## Behaviour

- Requests carry the pinned API version and a random idempotency key on every mutation; only
  retryable errors are retried, with full-jitter backoff and `Retry-After` honoured.
- Realtime tries WebSocket, then Server-Sent Events, then long-poll, and reconnects with full jitter
  between 1 and 60 seconds.
- In the background the connection closes; in the foreground the SDK refreshes the counters,
  reconnects, syncs, and drains the offline queue last.
- When content cannot be fetched for a content-free push, a generic text is shown instead.
- Device status signals are sent with a time to live and are never logged.

## Development

The models in `relay/src/generated` are generated from the subscriber OpenAPI contract by a pinned
OpenAPI Generator; run `scripts/generate.sh` and commit the result. CI regenerates and fails on any
difference. Dependencies are locked (`relay/gradle.lockfile`) and verified
(`gradle/verification-metadata.xml`).

Licensed under Apache-2.0.
