# @esuiss/relay-elements

[Relay](https://github.com/e-suiss/relay)'s inbox, toasts, preference center and webhook portal as web components. Use them from Vue, Angular, Svelte, Phoenix LiveView or plain HTML. Each element renders the matching component of [`@esuiss/relay-react`](../react) into its shadow root, so behaviour, texts and accessibility are identical everywhere; the package bundles everything it needs.

## Install

```sh
npm install @esuiss/relay-elements
```

## Quick start

```html
<relay-inbox-popover></relay-inbox-popover>
<relay-toaster></relay-toaster>
<relay-preference-center></relay-preference-center>

<script type="module">
  import { configureRelay, defineRelayElements } from "@esuiss/relay-elements";

  configureRelay({
    baseUrl: "https://relay.example.com",
    token: () => fetch("/api/relay-token", { method: "POST" }).then((r) => r.text()),
    locale: "tr",
    links: { accessConsentUrl: "https://access.example.com/consents" },
  });
  defineRelayElements();
</script>
```

Without any script configuration, attributes are enough:

```html
<script type="module" src="https://cdn.example.com/@esuiss/relay-elements/dist/auto.js"></script>
<relay-inbox base-url="https://relay.example.com" token-url="/api/relay-token"></relay-inbox>
```

`token-url` is an endpoint of your own backend that answers with the subscriber token (plain text or JSON with `token` or `access_token`). Only narrow tokens are accepted: a subscriber token, and for `relay-webhook-portal` a portal token (`portal-token-url` or `portalToken`).

## Elements

| Element                   | Attributes                                                |
| ------------------------- | --------------------------------------------------------- |
| `relay-bell`              | `badge-source` (`unseen` or `unread`)                     |
| `relay-inbox`             | `categories`, `tags` (comma separated), `heading-level`   |
| `relay-inbox-popover`     | `badge-source`, `categories`, `tags`, `heading-level`     |
| `relay-toaster`           | `duration` (milliseconds)                                 |
| `relay-preference-center` | `focus-category`, `marketing-categories`, `heading-level` |
| `relay-webhook-portal`    | `heading-level`                                           |

Every element also takes `locale`, `color-scheme`, `base-url`, `token-url` and `portal-token-url`, a `config` property for its own configuration and a `props` property for options that attributes cannot carry. Elements that share a configuration share one inbox and one realtime connection.

## Events

| Event                    | Detail                                                                          |
| ------------------------ | ------------------------------------------------------------------------------- |
| `relay-open-preferences` | `{ category }`: the user asked for a category's preferences from an inbox item. |
| `relay-item-open`        | `{ item }`: the user opened an inbox item.                                      |

Both bubble out of the shadow root.

## Displayed notification reporting

Relay can measure how often the same notification is shown more than once. The measurement is off by default; turn it on in the configuration:

```js
configureRelay({
  baseUrl: "https://relay.example.com",
  token,
  reportDisplayedNotifications: true,
});
```

Every inbox item the elements render is then queued as the SHA-256 digest of its identifier with the time it was shown; the identifier and the content never leave the browser. The queue is sent in batches of up to 100: when 20 are waiting, every 30 seconds and when the page becomes hidden. A failed batch is retried on the next flush with the same Idempotency-Key, and batches older than 24 hours are dropped. `reportDisplayedNotification(id)` reports a notification your page showed itself, and `flushDisplayedNotifications()` sends the queue at once; both take an optional configuration and use the global one otherwise.

## Theming

Set CSS custom properties on the element or any ancestor; they cross the shadow boundary and win over the configured theme:

```css
relay-preference-center {
  --relay-color-accent: #0b5c3b;
  --relay-color-accent-text: #ffffff;
  --relay-radius: 4px;
}
```

## Framework notes

- Vue: mark the tags as custom elements (`compilerOptions.isCustomElement: (tag) => tag.startsWith("relay-")`).
- Angular: add `CUSTOM_ELEMENTS_SCHEMA` to the component or module.
- Svelte and LiveView: use the tags directly; give LiveView containers `phx-update="ignore"`.

## Development

```sh
npm ci
npm test        # Vitest
npm run demo    # demo page on http://localhost:4174/demo/
npm run e2e     # Playwright and axe-core
```

## License

Apache-2.0
