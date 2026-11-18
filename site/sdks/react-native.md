# React Native

`@esuiss/relay-react-native` covers push device registration, push receipts, the inbox with realtime updates and an offline queue, device status signals, and ready-made inbox and preference components.

```sh
npm install @esuiss/relay-react-native
```

`react` and `react-native` are peer dependencies. The package has no runtime dependencies and pulls in no push library: you connect your own (Firebase Messaging, Notifee, expo-notifications or a native module) through a small adapter.

## Quick start

<<< @/examples/react-native/App.tsx#app

`RelayProvider` starts the client and follows the app lifecycle: it closes the realtime connection in the background and, on return, refreshes the badge first, reconnects, synchronises and then sends queued changes. `storage` is durable storage such as AsyncStorage or a secure store.

## Subscriber token

`tokenProvider` returns `{ token, expiresAt? }`. Your app exchanges its user's Access token for a Relay subscriber token (`POST /v1/subscriber/token`) through your backend. The SDK asks again with `forceRefresh: true` after an expired-token answer and renews the realtime connection before the token expires. Request the scopes the features need: `inbox:read inbox:write preferences devices:write presence:write`.

## Push

Pass `push: { adapter, categories }` to `createRelayClient`. The adapter wraps your push library: the token and its refreshes, the OS permission, Android channels and their importance, and showing and removing notifications. The SDK registers the token, permission and channel importances on every start and whenever they change. Android channel ids are `relay.<category>.<level>` and never change between versions.

Shown notifications record a `displayed` receipt and opened ones a `clicked` receipt; receipts made offline are sent later with the same idempotency key.

## Components

| Component          | What it shows                                                                                                   |
| ------------------ | --------------------------------------------------------------------------------------------------------------- |
| `InboxBell`        | A bell with the unseen badge, capped at `99+`                                                                   |
| `InboxList`        | Items with read, unread, archive and hide, and a five-second undo for archive and hide                          |
| `PreferenceCenter` | Category by channel switches, locked categories with their reason, and a three-option step when turning one off |

Components set accessibility roles, labels and states, never rely on colour alone, keep touch targets at least 44 points and meet WCAG 2.2 AA contrast. Texts follow the locale (`tr` or `en`) and can be replaced.
