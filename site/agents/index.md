# Relay for agents

AI agents need what notification systems already do, plus one thing more: asking a person or another system a question, waiting durably for the answer, and escalating when nobody responds. Relay gives agents the same delivery engine people get.

## The building blocks

**Agent recipients.** An agent is a recipient like a subscriber, with its identity in Access. It receives notifications, events and responses, and can subscribe to topics.

**The mailbox.** Everything for an agent lands in its durable, ordered mailbox. The agent leases records, handles them and acknowledges them; a record that is not acknowledged before its lease ends is delivered again, and one delivered too often moves to a dead-letter view. Pushes, webhooks and A2A push notifications only wake the agent up: the records wait in the mailbox, so a lost wake-up loses nothing.

**Waitpoints.** A waitpoint says "a response with this key is expected by this deadline". A `question` or a `review` asks its responders for one response that fits a JSON Schema; an `event` waitpoint waits for an event with a correlation key. Relay invites the responders on their channels, escalates through tiers when nobody answers, never loses an early reply, and puts the result in the waiter's mailbox. The waiter never answers its own waitpoint.

**Responses.** A response records the value, who answered, on which channel and with which evidence level (`channel_claim`, `relay_session` or `access_aas_ref`). It is a fact about a channel, never an authorisation: decisions to act are made in Access.

**Protocols.** Relay serves an [MCP server](./mcp), receives and sends A2A push notifications with the same retries, signatures and replay as webhooks, and carries AG-UI events on the realtime channel unchanged.

## The follow pattern

To never miss a record and never handle one twice, open the wake-up source first, then read what the mailbox already holds, then read again on every wake-up, and handle each record once by its id. The server SDKs ship this as a helper (`followMailbox` in TypeScript, `follow` in Elixir and Java, `FollowAsync` in .NET).

## Stay safe

Notifications carry content from people and other systems, so treat everything an agent reads from Relay as untrusted data. Read the [security guide](./security) before you connect an agent that can act.

## Give your agent the skills

The [skills package](./skills) is a set of plain Markdown files that teach an agent how to use Relay through MCP or the API: sending, waiting for responses, working the mailbox and staying safe.
