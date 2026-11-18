# @esuiss/relay-react

Ready-made React components for [Relay](https://github.com/e-suiss/relay): an inbox with bell and badge, toasts, a preference center and an embeddable webhook portal. They run on the headless browser client of [`@esuiss/relay`](../typescript) and hold only narrow tokens: a subscriber token for the inbox, toasts and preferences, and a portal token minted by your backend for the webhook portal. A secret never reaches the browser.

## Install

```sh
npm install @esuiss/relay-react @esuiss/relay react react-dom
```

## Quick start

```tsx
import { InboxPopover, PreferenceCenter, RelayProvider, Toaster } from "@esuiss/relay-react";

export function App() {
  return (
    <RelayProvider
      baseUrl="https://relay.example.com"
      token={() => fetch("/api/relay-token", { method: "POST" }).then((r) => r.text())}
      locale="tr"
      brand={{ name: "Example", logoUrl: "/logo.svg", theme: { accent: "#0b5c3b" } }}
      links={{ accessConsentUrl: "https://access.example.com/consents" }}
    >
      <InboxPopover />
      <Toaster />
      <PreferenceCenter />
    </RelayProvider>
  );
}
```

The token provider returns a Relay subscriber token that your backend obtained with the token exchange. The components refuse anything else, such as an Access token, before a request is made.

## Components

| Component               | What it does                                                                                                                                                                                                                                                                                                                                                                                               |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Bell`                  | Bell with a server-computed badge (`unseen` or `unread`), shown up to `99+`.                                                                                                                                                                                                                                                                                                                               |
| `Inbox`, `InboxPopover` | Category and tag filters, unread filter, read and unread, archive, delete (the item is hidden), snooze, a shortcut to the item's category preferences and "mark all as read" for the filtered view with a short undo and an optimistic badge. Agent-sourced items are marked, awaiting responses show processing, answered and "no longer expected", and approvals only link to your Access approval page. |
| `Toaster`               | Toasts for notifications that arrive while the page is open. They stay while hovered or focused and can always be dismissed.                                                                                                                                                                                                                                                                               |
| `PreferenceCenter`      | Category × channel matrix with global channel switches, locked categories with whom the lock serves, administrator and device-settings states, "Permission pending · Allow", the Instant / Digest / Never step with nothing preselected, notification types, muted items, weekly schedule and quiet hours. Marketing consents are shown read-only with a link to Access.                                   |
| `WebhookPortal`         | Endpoints (add, edit, disable, archive) with the address check's answer at the field, event types from your catalog, endpoint health and disable reason, signing key rotation, test events, the delivery log with attempts, single resend and resend of failed deliveries in a time range.                                                                                                                 |

Give the portal its own token:

```tsx
<RelayProvider baseUrl="https://relay.example.com" portalToken={() => getPortalToken()}>
  <WebhookPortal />
</RelayProvider>
```

## Theming

Every colour and shape is a CSS custom property, such as `--relay-color-accent`, `--relay-color-text`, `--relay-radius` and `--relay-font-family`. Set them in your stylesheet, or pass a `theme`, a `brand` and a sub-tenant's `subtenantBrand` (it wins where it sets a value). `brand.darkTheme` holds the tokens for the dark scheme; `colorScheme` is `light`, `dark` or `auto`.

## Languages

Turkish and English ship with the package; `locale` picks one, and `messages` overrides single texts. Both languages are tested to have the same keys and placeholders.

## Accessibility

The components target WCAG 2.2 AA: every control works with the keyboard, focus is visible, targets are at least 24 px, statuses always carry text next to any colour, and live regions announce changes. The test suite runs axe-core with Playwright over a demo page in both languages and both colour schemes.

## Testing your app

`@esuiss/relay-react/testing` has an in-memory Relay (`createFakeRelay`, `demoRelay`) that answers the operations the components use.

## Development

```sh
npm ci
npm test        # Vitest
npm run demo    # demo page on http://localhost:4173/demo/
npm run e2e     # Playwright and axe-core
```

## License

Apache-2.0
