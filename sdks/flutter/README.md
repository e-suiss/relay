# esuiss_relay

Flutter client for [Relay](https://github.com/e-suiss/relay): the in-app inbox with realtime updates, push device registration, push receipts, device status signals and the subscriber's notification preferences, plus ready-made inbox and preference widgets.

The client only ever holds a short-lived **subscriber token** that your app obtains. It cannot send events, cannot change the subscriber's profile or consents, and never holds secret credentials.

## Install

```yaml
dependencies:
  esuiss_relay: 0.1.0
```

## Quick start

```dart
import 'package:esuiss_relay/esuiss_relay.dart';

final relay = RelayClient(
  baseUrl: Uri.parse('https://relay.example.com'),
  tokenProvider: ({required bool forceRefresh}) async {
    final t = await myBackend.relaySubscriberToken(force: forceRefresh);
    return SubscriberToken(t.accessToken, expiresAt: t.expiresAt);
  },
  push: MyFirebaseAdapter(),
  categories: const [
    RelayCategory('order_updates', RelayMessageClass.transactional),
    RelayCategory('campaigns', RelayMessageClass.marketing),
  ],
  locale: 'tr-TR',
  timezone: 'Europe/Istanbul',
);

await relay.start();
RelayLifecycleObserver(relay).attach();
```

```dart
RelayScope(
  client: relay,
  child: Scaffold(
    appBar: AppBar(actions: [RelayInboxBell(onPressed: openInbox)]),
    body: const RelayInboxList(),
  ),
);
```

## Push

The SDK talks to your push library through `RelayPushAdapter`, so it does not depend on Firebase or any other push SDK. Implement the adapter with the library you already use, then hand incoming payloads to the client:

```dart
FirebaseMessaging.onMessage.listen((m) {
  relay.pushHandler?.handle({'notification': m.notification?.toMap(), 'data': m.data}, foreground: true);
});
```

- The token is registered on every start, refreshed with `previous_token`, and the operating system permission, Android channel importances and interruption permissions (critical alerts and time-sensitive on iOS, Do Not Disturb access on Android, from `getInterruptionCapabilities`) are reported with it. Leave a permission null when it is not known; nothing is reported for it.
- Android channels have stable ids, `relay.<category>.<level>`; create them once through `relayAndroidChannels`.
- Content-free pushes carry only an opaque id. The client fetches the content from Relay by that id with the subscriber token; when it cannot be fetched, a generic text is shown instead. Pass another `RelayPushContentSource` to change this.
- Shown and opened notifications are reported with `displayed` and `clicked` receipts; receipts made offline are sent later.
- A notification read on another device is removed from this one.
- On iOS, content-free notifications are completed by a Notification Service Extension, which comes from the native iOS SDK.

## Displayed notification reporting

Off by default. Turn it on to help measure notifications shown more than once on a device:

```dart
final relay = RelayClient(
  baseUrl: Uri.parse('https://relay.example.com'),
  tokenProvider: myTokenProvider,
  reportDisplayedNotifications: true,
);
```

- Every notification the SDK shows (a push with fetched content, an item rendered by `RelayInboxList`) is queued as a SHA-256 digest of its notification id and the time it was shown. The id itself and the content are never sent.
- Notifications your app shows on its own can be reported with `relay.reportDisplayedNotification(notificationId)`.
- The queue is sent at 20 items, every 30 seconds and when the app goes to the background, at most 100 per request. A batch that fails is retried with the same idempotency key and dropped after 24 hours.

## Inbox

- Opens the realtime stream before reading the list, then applies buffered events by item id and version.
- WebSocket first, then Server-Sent Events, then long-polling; reconnects with exponential backoff and full jitter.
- Intents made offline are queued in order, one per item; a conflicting change from another device wins quietly.
- When the app returns to the foreground: counters, stream, sync, then the offline queue.

## Widgets

`RelayInboxBell`, `RelayInboxList` and `RelayPreferenceCenter` follow your `ThemeData`, or a `RelayThemeData` extension for brand colours, speak Turkish and English, and meet WCAG 2.2 AA contrast and touch target sizes.

- The inbox list labels notifications sent by an AI agent. An item awaiting a response shows its options as buttons, then whether the response is being processed, who answered and when, or that a response is no longer expected. An approval item is never answered in the app: it only links to the approval page in your account, opened through `onOpenUrl`.
- The preference center shows the subscriber's marketing consents read-only. Pass `accessConsentUrl` and `onOpenUrl` to add a link where they can be changed; without them no link is shown.

## Development

```sh
flutter pub get --enforce-lockfile
dart run tool/generate.dart
dart format --set-exit-if-changed .
dart analyze --fatal-infos
flutter test
```

Models under `lib/src/generated` are generated from the OpenAPI contract in `contracts/`; do not edit them by hand. `./regenerate.sh` regenerates them in place with the pinned generator. When this package or its workflow changes, CI regenerates them and fails on any difference; a contract change alone is picked up by a regeneration pull request.

## License

Apache-2.0
