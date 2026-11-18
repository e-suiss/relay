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

- The token is registered on every start, refreshed with `previous_token`, and the operating system permission and Android channel importances are reported with it.
- Android channels have stable ids, `relay.<category>.<level>`; create them once through `relayAndroidChannels`.
- Content-free pushes carry only an opaque id. Supply a `RelayPushContentSource` to fetch the content; when it cannot be fetched, a generic text is shown instead.
- Shown and opened notifications are reported with `displayed` and `clicked` receipts; receipts made offline are sent later.
- A notification read on another device is removed from this one.
- On iOS, content-free notifications are completed by a Notification Service Extension, which comes from the native iOS SDK.

## Inbox

- Opens the realtime stream before reading the list, then applies buffered events by item id and version.
- WebSocket first, then Server-Sent Events, then long-polling; reconnects with exponential backoff and full jitter.
- Intents made offline are queued in order, one per item; a conflicting change from another device wins quietly.
- When the app returns to the foreground: counters, stream, sync, then the offline queue.

## Widgets

`RelayInboxBell`, `RelayInboxList` and `RelayPreferenceCenter` follow your `ThemeData`, or a `RelayThemeData` extension for brand colours, speak Turkish and English, and meet WCAG 2.2 AA contrast and touch target sizes.

## Development

```sh
flutter pub get --enforce-lockfile
dart run tool/generate.dart
dart format --set-exit-if-changed .
dart analyze --fatal-infos
flutter test
```

Models under `lib/src/generated` are generated from the OpenAPI contract in `contracts/`; do not edit them by hand.

## License

Apache-2.0
