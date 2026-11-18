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
notification permission, each channel's current importance and the DND access status on every launch;
`SystemNotificationSettingsReader` reads them, and a custom reader that leaves `dndAccess` unset reports
nothing, so Relay keeps the level it has.

Compose:

```kotlin
RelayThemeProvider(RelayTheme(accent = brandColor)) {
    RelayInbox(client.store)
    RelayPreferencesScreen(
        model = RelayPreferencesModel(client.preferences, categories, SystemNotificationSettingsReader(context)),
        consentChangeUrl = "https://account.example.com/consents",
    )
}
```

The inbox labels items sent by an AI agent and shows each waitpoint's state: its options while it
awaits a response, then processing, who answered and when, or that it is no longer awaited. An approval
is never answered in the app; its only action opens the approval page in the account. The preference
centre shows the subscriber's consents read-only, with a link to change them when you pass
`consentChangeUrl`.

## Displayed notification reporting

Relay can measure how often the same notification is shown twice on a device. Reporting is off by
default; turn it on in the configuration:

```kotlin
RelayConfiguration(
    baseUrl = "https://relay.example.com",
    appIdentifier = context.packageName,
    tokenProvider = { refresh -> myBackend.relaySubscriberToken(refresh) },
    reportDisplayedNotifications = true,
)
```

The SDK then reports every push the data-message handler shows and every item the `RelayInbox`
component shows. If your app shows a notification itself, report its identifier:

```kotlin
client.displayed.report(notificationId)
```

Only the SHA-256 digest of the identifier and the time it was shown leave the device, never the
identifier or any content. Reports are sent in batches of up to 100 when 20 are waiting, every 30
seconds and when the app goes to the background. A failed batch is retried with the same idempotency
key on the next flush and dropped after 24 hours.

## Behaviour

- Requests carry the pinned API version and a random idempotency key on every mutation; only
  retryable errors are retried, with full-jitter backoff and `Retry-After` honoured.
- Realtime tries WebSocket, then Server-Sent Events, then long-poll, and reconnects with full jitter
  between 1 and 60 seconds.
- In the background the connection closes; in the foreground the SDK refreshes the counters,
  reconnects, syncs, and drains the offline queue last.
- A content-free push carries only its delivery id; the SDK fetches the content over TLS with the
  subscriber token. When it cannot be fetched, a generic text is shown instead and the push payload is
  never used as content.
- Device status signals are sent with a time to live and are never logged.

## Development

The models in `relay/src/generated` are generated from the subscriber OpenAPI contract by a pinned
OpenAPI Generator; run `regenerate.sh` and commit the result. CI regenerates and fails on any
difference. Dependencies are locked (`relay/gradle.lockfile`) and verified
(`gradle/verification-metadata.xml`).

Licensed under Apache-2.0.
