This is an English summary of the Turkish specification in docs/spec/; on any difference, the specification wins.

# Relay at a glance

English translation of the "Kısaca Relay" section of the specification. This section is a summary of the spec. The normative text is in the numbered sections; they win on any conflict. No decision IDs are assigned in this section. Section references (§) and IDs point into [`spec/`](./spec/README.md).

## What is Relay?

Relay is Suiss's **notification, messaging and event orchestration platform**. When a product or system says "this happened", Relay takes that event and:

- decides who is notified, through which channel, and when (workflow, route, preference, quiet hours, time zone);
- applies consent and regulatory rules (İYS, one-click unsubscribe, country rules);
- prepares the message in the right language and in a form suited to the channel (template, localization, brand);
- hands it to the provider, retrying or falling over to another channel when needed (push, email, SMS, WhatsApp, in-app, webhook and event destinations);
- records what happened, with evidence: delivered, failed, unknown, or **why it was not sent**.

Relay delivers to people, services, devices and AI agents with the same engine. For agents it additionally offers a wait point while awaiting a reply, a durable mailbox, and the standard agent protocols (A2A, MCP, AG-UI).

The single question Relay answers ([§1.5](./spec/01-executive-definition.md)):

> **"How will this event or message reach the right person, service, device or agent?"**

Relay is open source (Apache-2.0). The same code runs both self-hosted by an organization and operated by Suiss (SaaS); no feature is cloud-only (MD-4). The runtime is Elixir/OTP; its required components are PostgreSQL and Valkey (MD-5, MD-6). Turkish regulation is an input to the architecture; EU and US rules are added as rows in the same data table (MD-17).

## What problem does it solve?

Every product sends notifications, and every team rewrites the same things: channel selection, retry, provider fallback, preference center, İYS, quiet hours, delivery tracking, inbox, webhooks. Having each product write these separately leads to three outcomes:

| Problem | Outcome | Relay's answer |
|---|---|---|
| Rules are scattered | One product applies quiet hours, another does not; one channel skips İYS | A single decision layer: gates cannot be bypassed with a flag (MD-14) |
| "Did it go out?" is unknown | The user says "the code didn't arrive" and nobody can find out why | An append-only delivery ledger; every message not sent is visible with a reason code (MD-12, MD-15) |
| The agent world is left unserved | An agent asks a human a question, but the reply is lost, delayed, or it is unclear who gave it | Wait point, early-reply buffer, reply with channel evidence level (MD-3, MD-11) |

**Why now?** Agents work by waiting for replies from people and from each other. Today's notification platforms send one way; durable execution engines know how to wait but do not know how to reach a person, escalate, or apply channel rules. Relay is the delivery and reply layer between the two ([§4.4](./spec/04-landscape-decisions.md)).

## What it is not

| Relay is not ... | Owner of that job | Relay's role there |
|---|---|---|
| A source of authority or approval | Access | Delivers the approval invitation and collects the reply; a reply is not authority (MD-2) |
| A workflow / durable execution engine (checkpoint, resume, compensation) | Executor, LangGraph, customer code | Holds the wait point, matches the reply, delivers the "resolved" event (MD-3) |
| A human work and approval queue | Work | Applies Work's escalation policy and reaches the person |
| An identity provider (IdP) | Access or another OIDC IdP | Takes operator and subscriber identity from the connected IdP |
| A system that generates and verifies OTP codes | Access or the sending product | Delivers the code; applies destination protections (number rate limit, SMS pumping) |
| Marketing automation (segment engine, journeys) | The tenant's own system | Offers topic subscriptions and sending to lists (F-5) |
| A transport layer (APNs, FCM, SMTP, SMS carrier) | Platforms and providers | Uses them; in SaaS it does not operate its own mail server (F-3) |
| An analytics database (OLAP) | The tenant's data warehouse | Ready-made reports + exporting the event stream to the tenant's destination (F-7) |
| A platform that runs customer code | — (forbidden) | Customization is done through data, templates and allowlists (MD-16) |

The full list of things Relay will never do is in [§2.7](./spec/02-product-thesis.md). The most important:

- **Delivery is not approval.** A button press, an SMS reply or "seen" is never proof of authority.
- **No silent loss.** Every notification not sent is recorded with a reason code and is visible in the dashboard, in webhooks and in metrics.
- **No physical deletion.** Deletion is done through soft deletion and crypto-shredding (Access OP-73, Access OP-74).
- **No instructions are written to agents.** What goes to an agent is a structured message with typed fields; text from humans or external sources is carried separately, marked as "untrusted content".

## Core concepts

Precise definitions are in [§5](./spec/05-ontology.md).

| Concept | Meaning | Example |
|---|---|---|
| **Tenant** | A customer using Relay; it has its own data, keys and settings | An e-commerce company |
| **Sub-tenant** | A single-level brand/customer unit inside a tenant; inherits settings from the tenant | Each enterprise customer of a B2B software product |
| **Environment** | Separate `live` and `test` data planes per tenant; the processing pipeline is the same | A notification sent with a test key does not reach a real user |
| **Recipient (subscriber)** | The person the notification is meant to reach; has addresses, devices, a language and a time zone | Ayşe: email, phone, two devices, `tr-TR`, `Europe/Istanbul` |
| **Agent recipient** | An AI agent registered in Relay; has delivery endpoints and a mailbox | A purchasing agent |
| **Event** | A "this happened" input arriving at Relay; it triggers a workflow | `order.shipped` |
| **Workflow** | A versioned definition of the steps to take for an event | Send push → wait 1 hour → if not seen, email |
| **Route policy** | A named rule saying in which order, or together, channels are tried | "Push first, SMS if it fails" |
| **Message class** | One of seven fixed top-level classes; most rules depend on it | `security`, `transactional`, `marketing`, `action_required` … |
| **Category** | A notification type defined by the tenant; it is bound to a class | "Shipping status" → `transactional` |
| **Template** | Versioned content in a channel × language matrix | Push title + body, email HTML + plain text |
| **Preference** | The recipient's notification wishes: category × channel, quiet hours, digest | "I don't want campaigns by SMS" |
| **Consent** | A legal opt-in/opt-out record for commercial messages; separate from preference | An email opt-in registered in İYS |
| **Notification, delivery, attempt** | A notification is the logical message; a delivery is the intent to send on a specific channel to a specific destination; an attempt is a single external request | One notification → push and email deliveries → two attempts on email |
| **Delivery ledger** | The immutable record of every delivery event; status is derived from it | `sent` → `delivered` |
| **Skip reason** | The machine-readable reason and rule for a notification that was not sent (`reason` + `rule_id`) | "Quiet hours", "İYS opt-out", "duplicate content" |
| **Wait point** | A record of "a reply is expected for this key, deadline X" | The agent's question "Do you approve this order?" |
| **Mailbox** | A durable, sequence-numbered message record per recipient; human face is the inbox, agent face is lease/ack | When the agent wakes up, it reads what it missed in order |
| **Topic** | A subject that can be subscribed to; fanout happens through it | "Project X updates" |
| **Event destination** | An external endpoint to which Relay delivers events: HTTPS webhook, queue, object store | The tenant's Kafka topic |
| **Kill switch** | The single mechanism that stops sending by scope × destination × class | "Stop the SMS for this campaign" |

## Core principles

1. **Independent but frictionless.** Relay works on its own without Access; when Access is connected, they work together with a single setting and customer code does not change (MD-1).
2. **Relay is not a source of authority.** Delivery, ack, seen and channel replies are not authority or approval (MD-2).
3. **Waiting belongs to Relay, execution to the waiter.** Relay holds the wait point and the delivery; checkpointing and resuming are on the waiting side (MD-3).
4. **The class determines the rules.** The message class is assigned at acceptance and does not change; lane, priority ceiling, preference and compliance rules derive from the class (MD-8).
5. **No silent loss.** Every decision is recorded with a rule ID (MD-12).
6. **Truth lives in Postgres.** Valkey, push, realtime and webhooks are only signals and accelerators (MD-6, MD-15).
7. **Gates fail closed.** Compliance and security gates cannot be bypassed with a flag; a tenant rule can only tighten (MD-14).
8. **No physical deletion, no cross-region data flow** (MD-9, MD-10).

## Relationship with Access

| Situation | Behavior |
|---|---|
| Access without Relay | Access sends its own messages through its built-in direct-send mode (SMTP + a single HTTP SMS provider, simple retry) |
| Access with Relay | All of Access's human-facing messages go through Relay; Access is an isolated platform tenant in Relay |
| Relay without Access | Its own API keys, operator login, subscriber token; standard OIDC with another IdP |
| Relay with Access | Operator login and step-up, subscriber token, agent identity and marketing consent come from Access; audit records are linked |

Details: MD-1, [§7](./spec/07-ecosystem-boundaries.md), Access E40.
