# Concepts

Relay takes an event from your product, decides who should hear about it, on which channel and when, delivers it and records what actually happened. This page names the parts. Each concept has one name, used the same way in the API, the console and these docs.

## Accounts and environments

**Tenant** (`tenant`). The customer account that uses Relay. Settings, provider accounts, templates, workflows, recipients and every record belong to one tenant, and tenants are isolated from each other. A tenant chooses its `default_timezone` and `default_locale` when it is created; there is no system default.

**Subtenant** (`sub_tenant`). One of your own customers or brands inside your tenant, one level deep. It can carry its own branding, sender identities, provider account, preference defaults and inbox scope; whatever it does not set comes from the tenant.

**Environment**. Every tenant has `live` and `test`. Both run the same pipeline; on `test` the last step uses a fake provider and a virtual clock is available.

**API client** (`api_client`). The machine identity your backend uses, defined in Access with OAuth 2.0 client credentials and bound to one tenant and one environment. Relay has no API keys of its own and stores no client secrets.

## Recipients

**Subscriber** (`subscriber`). A person: profile, contact addresses, devices, time zone and locale, preferences, consents and an inbox. A subscriber is created when a request carries contact details for an id Relay does not know; an unknown bare id is refused, so no empty profiles appear.

**Agent** (`agent`). A software agent that receives notifications, events and responses. Its identity lives in Access; in Relay it has delivery endpoints, a mailbox and topic subscriptions.

**Topic**. A named audience that subscribers and agents subscribe to; an event sent to a topic reaches its subscribers.

## Sending

**Event** (`event`). Something happened. It arrives through `POST /v1/events`, as native JSON or as a CloudEvent, and names a workflow (or a CloudEvents type mapped to one).

**Workflow** (`workflow`). The versioned steps that turn an event into notifications: channel, wait, digest, throttle, condition, wait for event, time window and webhook. Published versions never change. A workflow is written in the visual editor, as a file in git, or with an SDK; all three produce the same definition.

**Notification** (`notification`). The message one event produces for one recipient. It is created once per recipient and its plan is fixed when it is created.

**Delivery** (`delivery`). One attempt to reach a recipient on one channel and target (an address or a device). A fallback opens a new delivery linked to the previous one.

**Route policy** (`route`). A named, reusable way of choosing channels: `fallback` (try in order), `fanout` (send to all), `last_active` (the channel or device used last) or `user_preference`, optionally escalating when a message is not seen.

**Digest** (`digest`). A step that collects events over a window and sends one notification for them. An empty digest is never sent; a digest with one event is that event.

## Policy

**Message class**. Every notification has one: `security`, `transactional`, `operational`, `marketing`, `social` and the others. The class drives the rules: marketing needs consent, security cannot be muted.

**Category**. A tenant-defined group of notification types, the unit people set preferences on. Locked categories cannot be turned off, and say why.

**Preference** (`preference`). What a person wants: `opt_in`, `opt_out` or `unset` (which falls back to the category default), at four levels: category and channel, notification type, a single muted object, and a weekly schedule. All levels must allow a message.

**Consent** (`consent`). The legal record of a commercial message permission: `none`, `granted` or `revoked`, per brand, channel and recipient. Relay keeps a copy from Access and checks it on every send.

**Suppression** (`suppression`). A block on an address or device: hard bounce, complaint, invalid address, repeated soft bounce or a manual entry.

**Decision**. The outcome of a rule for a delivery: `skip`, `defer`, `expire`, `cancel`, `pause` or `reject`. A decision is not an error. It carries a `rule_id` from one rule dictionary and a one-sentence explanation, and is kept with the delivery. See [Why didn't they get it?](./decisions).

## Inbox, mailbox and waiting

**Mailbox** (`mailbox`). A durable, ordered record per recipient. A person sees it as the in-app inbox (seen, read, archived, hidden); an agent leases records and acknowledges them, and an unacknowledged record is delivered again. A push or webhook only wakes the reader up; the record waits in the mailbox.

**Waitpoint** (`waitpoint`). "A response with this key is expected by this deadline." A question or review asks people for one response that fits a schema; an event waitpoint waits for an event. The result arrives in the waiter's mailbox. Whoever waits never answers its own waitpoint.

**Response** (`response`). What resolves a waitpoint: the value, who answered, on which channel and with which evidence level. A response is a fact about a channel, never an authorisation; authorisation happens in Access.

## Terms from other tools

Relay uses its own names. If you know another notification or workflow product, this is how its terms map:

| Elsewhere                                                                                         | In Relay                          |
| ------------------------------------------------------------------------------------------------- | --------------------------------- |
| Knock "tenant", Novu "tenant" or "context"                                                        | Subtenant                         |
| "subscriber", "recipient", "user"                                                                 | Subscriber                        |
| "batch", "digest"                                                                                 | Digest                            |
| "routing", "channel strategy", "fallback chain"                                                   | Route policy                      |
| "workflow trigger", "event"                                                                       | Event                             |
| "waitpoint token" (Trigger.dev), "awakeable" (Restate), `.waitForTaskToken` (AWS Step Functions) | Waitpoint                         |
| "send/recv with topic" (DBOS), "agent inbox"                                                      | Agent mailbox                     |
| "suppression list", "unsubscribe group"                                                           | Suppression, and preference       |
| A connector that reads your database                                                              | Your CDC tool, see [Change data capture](./cdc) |

## What Relay is not

- Not a marketing automation tool: there are no attribute-query segments or journeys. Compute your audience and send it as a list or a topic.
- Not a business process engine: a workflow is a notification flow, and Relay never calls your code at run time.
- Not an authority: approvals and permissions live in Access. A response collected by Relay is evidence, not consent to act.
- Not a one-time code service: Relay delivers codes you generate, but never creates, stores or checks them.
