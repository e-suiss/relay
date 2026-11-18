# @esuiss/relay

The TypeScript SDK for Relay. It ships four entry points:

| Import                         | For                                                                |
| ------------------------------ | ------------------------------------------------------------------ |
| `@esuiss/relay`                | Server client, webhook verifier, DPoP authorization, agent helpers |
| `@esuiss/relay/agent`          | Agent helpers only: waitpoints and the mailbox                     |
| `@esuiss/relay/webhooks`       | The raw-body webhook verifier only                                 |
| `@esuiss/relay/browser`        | The headless browser client behind the UI components               |
| `@esuiss/relay/service-worker` | Badge and notification click helpers for a service worker          |

Types and operations are generated from the Relay OpenAPI contract; the SDK always sends the API version it was generated from, so updating the package never changes behaviour behind your back.

## Server client

```ts
import { RelayServerClient, dpopAuthenticator } from "@esuiss/relay";

const relay = new RelayServerClient({
  baseUrl: "https://relay.example.com",
  authenticate: dpopAuthenticator({ accessToken: getAccessToken, keyPair }),
});

const accepted = await relay.call("createEvent", {
  body: {
    event: "order.shipped",
    to: { id: "user_42", email: "ada@example.com" },
    data: { order: "4821" },
  },
});

for await (const notification of relay.paginate("listNotifications", { query: { limit: 100 } })) {
  console.log(notification.id);
}
```

- Every mutating call gets an `Idempotency-Key`; pass `idempotencyKey` to use your own. Retries keep the same key.
- Only errors with `retryable: true` and requests that got no response are retried, with exponential backoff and full jitter, honouring `Retry-After`.
- Errors are typed: `AuthenticationError`, `ValidationError`, `RateLimitError`, `IdempotencyError`, `ServerError` (all `RelayApiError`), plus `RelayConnectionError`.
- Lists are lazy: pages are fetched only as you iterate.

Relay delivers at least once and, with durable idempotency, processes effectively once.

## Webhooks

Verify against the raw body, exactly the bytes that arrived:

```ts
import { verifyWebhook, WebhookVerificationError } from "@esuiss/relay/webhooks";

app.post("/relay", express.raw({ type: "*/*" }), async (req, res) => {
  try {
    const { id } = await verifyWebhook(req.headers, req.body, process.env.RELAY_WEBHOOK_KEY!);
    res.sendStatus(204);
  } catch (error) {
    if (error instanceof WebhookVerificationError) return res.sendStatus(400);
    throw error;
  }
});
```

Keys are `whpk_…` (Ed25519, signatures `v1a`) or `whsec_…` (HMAC, signatures `v1`); during a key rotation pass both.

## Agents

```ts
import { RelayAgent } from "@esuiss/relay";

const agent = new RelayAgent(relay);
const waitpoint = await agent.createWaitpoint(request);
const resolved = await agent.awaitWaitpoint(waitpoint.id);

await agent.followMailbox({
  open: (wake) => onWebhookHint(() => wake()),
  onRecord: (record) => handle(record),
});
```

A push, webhook or protocol notification only wakes the agent up; records wait in the mailbox, and `followMailbox` opens the wake-up source before it reads the mailbox and delivers each record once.

## Browser

The browser client holds only the subscriber's narrow-scoped token, never a secret.

```ts
import { InboxClient, RelaySubscriberClient } from "@esuiss/relay/browser";

const client = new RelaySubscriberClient({
  baseUrl: "https://relay.example.com",
  token: fetchSubscriberToken,
});
const inbox = new InboxClient({ client });
inbox.subscribe(({ items, counters }) => render(items, counters));
await inbox.start();

inbox.markRead(itemId);
const { undo } = inbox.archive(itemId, { undoable: true });
```

- Realtime over WebSocket, falling back to SSE and then long-poll; reconnects with backoff and full jitter.
- Opens the stream before it lists, and drops events not newer than what it holds.
- Intents go through an offline queue (one per item, ordered by `client_seq`); a conflict is accepted silently.
- Counters are re-read whenever the page comes to the foreground; a mismatch with the list is reported.
- One connection per browser: the tab holding a Web Lock leads and shares events over a BroadcastChannel.

In a service worker:

```ts
import { installServiceWorkerHandlers } from "@esuiss/relay/service-worker";

installServiceWorkerHandlers(self);
```

## Development

```sh
npm ci
./regenerate.sh    # regenerate from the contract
npm run typecheck && npm run lint && npm test
```

## License

Apache-2.0
