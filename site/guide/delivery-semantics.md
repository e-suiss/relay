# Delivery semantics per channel

"Delivered" means different things on different channels, and some channels can never prove it. Relay reports only what each channel can prove, from an append-only ledger of everything Relay, providers, devices and people told it.

## What each channel can prove

| Channel                        | `sent` means                         | `delivered` is proven by                                                   | Engagement it reports                                             | Signals that can drive decisions | Notes                                                                                         |
| ------------------------------ | ------------------------------------ | -------------------------------------------------------------------------- | ----------------------------------------------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------- |
| Email                          | The ESP or your SMTP server accepted | The provider's delivery event or a success DSN; a human click              | Opens (unreliable) and clicks, split into human and likely bot    | Human clicks only                | A bounce that arrives after delivery still counts and turns the delivery `failed`             |
| SMS                            | The provider accepted                | A delivery report (DLR) that says delivered                                | None                                                              | None                             | Reports can arrive hours late or never                                                        |
| WhatsApp                       | The provider accepted                | The `delivered` event                                                      | `read` (the recipient can turn it off) and interactive replies    | `read`                           | `read` can arrive before `delivered`; no `read` tells you nothing                             |
| Push (APNs, FCM, Web Push, HMS) | The provider accepted                | Only the "displayed" receipt from Relay's mobile or web SDK                | "Displayed" and "clicked" receipts from the SDK                   | SDK receipts                     | Provider acceptance is never reported as delivered                                            |
| In-app inbox                   | Not used                             | The inbox record was committed                                             | `seen`, `read`, `clicked`, `archived`                             | `seen`, `read`, `clicked`        | Delivered means stored in the inbox; seen is a separate fact                                  |
| Webhook channel                | Not used                             | The destination answered with success                                      | None                                                              | None                             | Retries follow the webhook schedule                                                           |
| Voice                          | The provider started the call        | The provider's answered or completed event                                 | Keypad input, where available                                     | None                             |                                                                                               |

### Push never claims "delivered"

APNs answering `200`, FCM accepting a message or a Web Push service answering `201` only means the provider took it. Without a receipt from the SDK on the device, a push delivery stays `sent` and reports show it as "accepted by the provider". Push has no delivery report to wait for, so it never becomes `unknown` either. Reports show the provider acceptance rate and the receipt-backed delivery rate separately.

## The status you read

The API and webhooks show one simple projection per delivery:

| `status`          | Meaning                                                                                          |
| ----------------- | ------------------------------------------------------------------------------------------------ |
| `queued`          | Accepted and waiting to be sent: scheduled, deferred or held by a rate limit                     |
| `sent`            | The provider accepted it; no definite proof of delivery yet                                     |
| `delivered`       | The channel's proof of delivery arrived (see the table above)                                   |
| `unknown_pending` | The short window passed without a definite answer; Relay is still listening                      |
| `unknown`         | The long window passed without a definite answer; a late answer still updates it                 |
| `failed`          | A definite failure, including a bounce (`failure.kind` tells them apart)                         |
| `skipped`         | Relay decided not to send it; `reason` and `rule_id` say why                                     |
| `expired`         | The message passed its `expires_at` before it could be sent                                      |
| `cancelled`       | It was cancelled before it was sent                                                              |

Delivery certainty only goes up: once `delivered`, a delivery is never downgraded by a later, weaker signal. A late definite answer always upgrades `unknown_pending` and `unknown`. `skipped`, `expired` and `cancelled` are final because nothing was sent.

### Honest `unknown`

On channels that report delivery asynchronously (SMS, email, WhatsApp, voice), two windows run after `sent`. When the short one passes, the delivery shows `unknown_pending`; when the long one passes, `unknown`. Relay never invents `delivered` or `failed` when a provider stays silent. The default windows per channel are on the [limits page](/reference/limits).

`unknown` never triggers an automatic resend or a fallback: whether to send again depends on the message (pointless for a one-time code, useful for a receipt, never for marketing), so it is your decision, made with a new request. Fallback moves on only after a definite failure.

## Engagement is a separate axis

Seen, read, clicked and archived are recorded with their own timestamps and sources, independently of delivery. A click can arrive on an email that shows `failed`; it is recorded, and a human click on an email proves delivery.

- Open tracking and link wrapping are off by default, and are never enabled for security messages or one-time code emails.
- Opens are never used in any decision and never count as proof of delivery. Machine opens (privacy proxies, security scanners) are flagged.
- Every click is classified as `human` or `likely_bot`; reports show them separately and only human clicks stop an escalation or a channel upgrade.
