# Flutter

`esuiss_relay` brings the in-app inbox with realtime updates, push device registration, push receipts, device status signals and the subscriber's preferences to Flutter, plus ready-made inbox and preference widgets.

```yaml
dependencies:
  esuiss_relay: 0.1.0
```

The client only ever holds a short-lived subscriber token that your app obtains. It cannot send events, cannot change the subscriber's profile or consents, and never holds secret credentials.

## Create the client

<<< @/examples/flutter/docs_examples.dart#client

## Show the inbox

<<< @/examples/flutter/docs_examples.dart#inbox

`RelayInboxBell`, `RelayInboxList` and `RelayPreferenceCenter` follow your `ThemeData` or a `RelayThemeData` extension for brand colours, speak Turkish and English, and meet WCAG 2.2 AA contrast and touch target sizes.

## Push

The SDK talks to your push library through `RelayPushAdapter`, so it does not depend on Firebase or any other push SDK. Pass your adapter as `push:` and hand incoming payloads to `relay.pushHandler`. Tokens are registered on every start, Android channels have stable ids (`relay.<category>.<level>`), content-free pushes are completed through a `RelayPushContentSource`, and displayed and clicked receipts are reported, including those made offline.

## Inbox behaviour

- Opens the realtime stream before reading the list, then applies buffered events by item id and version.
- WebSocket first, then Server-Sent Events, then long-polling; reconnects with exponential backoff and full jitter.
- Changes made offline are queued in order, one per item; a conflicting change from another device wins quietly.
