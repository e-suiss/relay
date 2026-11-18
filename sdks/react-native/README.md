# @esuiss/relay-react-native

React Native client for [Relay](../../README.md): push device registration, push receipts, the inbox with realtime updates and an offline queue, device status signals, and ready-made inbox and preference components with theming, Turkish and English texts and accessibility built in.

The client works only with a short-lived Relay **subscriber token** that your app obtains for its signed-in user. It never sends events, never writes the subscriber's profile or consents, and never holds a secret credential.

## Install

```sh
npm install @esuiss/relay-react-native
```

`react` and `react-native` are peer dependencies. The package has no runtime dependencies and does not pull in any push library: you connect your own (Firebase Messaging, Notifee, expo-notifications or a native module) through a small adapter.

## Quick start

```tsx
import AsyncStorage from '@react-native-async-storage/async-storage';
import {
  createRelayClient,
  InboxBell,
  InboxList,
  PreferenceCenter,
  RelayProvider,
} from '@esuiss/relay-react-native';

const relay = createRelayClient({
  baseUrl: 'https://relay.example.com',
  storage: AsyncStorage,
  locale: 'tr-TR',
  timezone: 'Europe/Istanbul',
  tokenProvider: async ({ forceRefresh }) => myBackend.relaySubscriberToken({ forceRefresh }),
  push: {
    adapter: myPushAdapter,
    categories: [
      { key: 'order_updates', class: 'transactional', name: 'Orders' },
      { key: 'campaigns', class: 'marketing', name: 'Offers' },
    ],
  },
});

export function App() {
  return (
    <RelayProvider client={relay} brand={{ primary: '#0B5FFF' }}>
      <InboxBell onPress={openInbox} />
      <InboxList onOpenItem={(item) => item.url && Linking.openURL(item.url)} />
      <PreferenceCenter />
    </RelayProvider>
  );
}
```

`RelayProvider` starts the client and follows the app lifecycle: it closes the realtime connection in the background and, on return, refreshes the badge first, reconnects, synchronises and then sends queued changes.

## Subscriber token

`tokenProvider` returns `{ token, expiresAt? }`. Your app exchanges its user's Access token for a Relay subscriber token (`POST /v1/subscriber/token`) and hands it to the SDK. The SDK asks again with `forceRefresh: true` after an expired-token answer and renews the realtime connection before the token expires. Request the scopes the features need: `inbox:read inbox:write preferences devices:write presence:write`.

## Push

Implement `PushAdapter` on top of your push library:

| Member                                                                             | Purpose                                                                           |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `platform`, `app`, `apnsEnvironment`                                               | `apns`, `fcm` or `hms`; bundle id or package name; APNs environment               |
| `getToken`, `onTokenRefresh`                                                       | the current token and its refreshes                                               |
| `getPermission`, `requestPermission`                                               | OS notification permission (`granted`, `denied`, `provisional`, `not_determined`) |
| `createAndroidChannels`, `getAndroidChannels`                                      | Android channels and their current importance                                     |
| `getInterruptionCapabilities`                                                      | Do Not Disturb access, Critical Alerts and time-sensitive permission              |
| `displayNotification`, `getDisplayedNotifications`, `removeDisplayedNotifications` | show and remove notifications                                                     |

The SDK registers the token, the permission, the interruption permissions and the channel importances on every start and whenever they change, and sends the previous token when the platform rotates it. Interruption permissions are `granted`, `denied` or `not_determined`: iOS reports Critical Alerts and time-sensitive, Android reports Do Not Disturb access. A permission the adapter reports as `unsupported`, or cannot read, is left out, and Relay keeps the level it has. `relay.devices.requestPermission()` asks for provisional authorisation on iOS only when every category the app starts with is `marketing` or `social`.

### Android channels

Channels are created per category and interruption level with ids that never change between app versions: `relay.<category>.<level>` with levels `passive`, `active`, `time-sensitive` and, for a category you declare `critical`, `critical`. Use `androidChannels(categories)` to inspect them and `androidChannelId(category, level)` to address one.

### Handling pushes

```ts
messaging().onMessage((message) => relay.push?.received(message, 'display'));
messaging().setBackgroundMessageHandler((message) => relay.push?.received(message, 'display'));
notifee.onForegroundEvent(({ detail }) => relay.push?.opened(detail.notification?.data));
```

`received` understands every Relay payload:

- **Content-free notifications** carry only the delivery id. By default the SDK fetches the content from Relay over TLS with the subscriber token (`inbox:read`); pass `contentSource` to fetch it elsewhere. When it cannot be fetched (not found, offline, timed out) the neutral text of the push or a generic text (`Yeni bildirim` / `New notification`) is shown; content never goes back into a push. On iOS the content of a content-free notification is fetched by a Notification Service Extension, which comes with the native iOS SDK.
- **Sync signals** refresh the badge; when nothing is unread, notifications shown by Relay are removed.
- **Read signals** remove a notification that was read on another device.

Shown notifications record a `displayed` receipt and opened ones a `clicked` receipt. Receipts wait on the device while offline and are sent with the same idempotency key until Relay records them.

### Displayed notification reporting

Relay can measure how often the same notification is shown twice on a device. This is off by default; turn it on with `reportDisplayedNotifications: true`:

```ts
const relay = createRelayClient({ ...options, reportDisplayedNotifications: true });

await relay.reportDisplayed(notificationId);
```

When it is on, every push the SDK shows or is told was shown, and whose notification id it knows, is queued, and `reportDisplayed` queues an id your app displayed itself. Only the SHA-256 digest of the id and the time it was shown leave the device, never the id or any content. The same id shown twice is reported twice. The queue is reported in batches of at most 100 when 20 are waiting, every 30 seconds and when the app goes to the background. A batch that fails stays on the device and is sent again with the same idempotency key; batches older than 24 hours are dropped.

## Inbox

```ts
relay.inbox.subscribe((snapshot) => render(snapshot.items, snapshot.counters));
await relay.intent(itemId, 'read', { interactive: true });
await relay.sync.readAll();
```

Changes are sent as intents in `client_seq` order from a durable queue that keeps only the newest intent per item. If another device changed the item first, the server state is accepted silently; `onConflicts` reports it only for a change the user just made on screen. Realtime uses WebSocket first, then Server-Sent Events, then long-polling, and reconnects with full-jitter exponential backoff.

### Waitpoints

```ts
await relay.waitpoints.respond(item.waitpoint.id, option.value, item.waitpoint.subject_digest);
```

A response is collected and passed on; it is never an approval. Approval items are answered only on the approval surface of your account system, which the item links to.

## Device status

```ts
relay.presence.update({ headphones: true, focus: false }, 300);
```

Signals are `worn`, `locked`, `headphones`, `focus` and `break`. Writes are limited to one per second, carry a time to live (5 minutes by default, at most 15) and are never stored, queued or logged by the SDK.

## Components

| Component          | What it shows                                                                                                                                                                                |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `InboxBell`        | bell with the unseen badge, capped at `99+`                                                                                                                                                  |
| `InboxList`        | items with read, unread, archive and hide, and a five second undo for archive and hide; the AI agent label; a waitpoint's state with its options as buttons, or for an approval only a link  |
| `PreferenceCenter` | category by channel switches; locked categories with their reason; push shown off when disabled in device settings; a three-option step (instant, digest, never) when a switch is turned off |
| `ConsentSummary`   | the subscriber's marketing permissions, read-only, with an optional link to change them in your account system (`consentManageUrl` on `PreferenceCenter`)                                    |

Theme with `scheme` (`light`, `dark` or `system`), `brand` (accent and radius, also per subtenant) and `theme` overrides. Texts follow the locale (`tr` or `en`) and can be replaced with `messages`. Components set accessibility roles, labels and states, never rely on colour alone, keep touch targets at least 44 points and ship colour tokens that meet WCAG 2.2 AA contrast.

## Development

```sh
npm ci
npm run generate
npm run typecheck && npm run lint && npm test
```

Models are generated from the subscriber API contract and the error catalog and committed under `src/generated/`. `./regenerate.sh` regenerates them in place with the pinned generator. When this package or its workflow changes, CI regenerates them and fails on any difference; a contract change alone is picked up by a regeneration pull request.

## License

Apache-2.0
