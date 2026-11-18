---
layout: home

hero:
  name: Relay
  text: Notifications, messaging and events
  tagline: Get an event from your product to the right person, service, device or AI agent, on the right channel, at the right time, and know exactly why when it was not sent.
  actions:
    - theme: brand
      text: First notification in 5 minutes
      link: /guide/getting-started
    - theme: alt
      text: Concepts
      link: /guide/concepts
    - theme: alt
      text: API reference
      link: /reference/

features:
  - title: Every channel
    details: Push, email, SMS, voice, WhatsApp, chat apps, an in-app inbox with realtime updates, and webhooks to HTTPS, queues and streams.
  - title: Decisions you can read
    details: Consent, preferences, quiet hours and kill switches are decisions with a rule id and a one-sentence explanation, never silent drops.
  - title: Honest delivery state
    details: Each channel reports only what it can prove. Push never claims "delivered" without a device receipt, and a silent provider shows as unknown.
  - title: Built for agents
    details: Waitpoints, durable agent mailboxes, an MCP server and a skills package. Messages to agents are data, never instructions.
  - title: Two dependencies
    details: PostgreSQL and Valkey. One Elixir release that runs as a single process or as separate api, worker and socket roles.
  - title: Open source, complete
    details: The console, components, test plane and SDKs are all in the self-hosted release. Nothing is locked behind a licence flag.
---

## The guarantee

Relay provides at-least-once delivery with durable idempotency, giving effectively-once processing. Every write takes an `Idempotency-Key`; a retry with the same key gets the stored response, and every event your webhook receives carries an id you deduplicate by. [Read how it works](/guide/guarantees).
