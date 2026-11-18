# Agent security guide

A notification stream carries untrusted content by design: a reply typed by a stranger, a ticket title, an email subject, an event from another system. An agent that reads Relay's mailbox reads that content. The defence is not filtering clever strings out of text; it is keeping privileges apart, so that what an agent reads can never become what it is allowed to do.

## What Relay does for you

- **Structured messages.** Messages to agents are structured data with typed fields, marked as untrusted content and labelled with their source. Relay never presents text from a person or another system as an instruction.
- **Signed envelopes.** Messages are signed with your tenant's key, and every inbound message carries a trust label.
- **Server-rendered approvals.** Questions and reviews are rendered by Relay with Markdown and HTML turned off; the text a responder agrees to (`claim_text`) is kept apart from the rest.
- **No self-approval.** The token that answers a waitpoint never reaches the agent that waits, and the responder can never be the waiter.
- **Responses are not authority.** A response, an acknowledgement or a result through MCP or A2A is a fact about a channel, never permission to act. Permission lives in Access.
- **Visible text only.** Hidden text is normalised away and links are checked against an allow list.

## What your agent must do

### 1. Process untrusted content without privileges

Read mailbox records, responses and event data in a context that has no tools and no secrets. A common shape is the **dual model**: a quarantined model reads the untrusted text and returns only structured values in a fixed schema (an enum, a number, an id it was given); a privileged model that never sees the raw text plans and calls tools using those values only.

```text
mailbox record ──▶ quarantined model (no tools, no secrets) ──▶ { "intent": "approve", "order_id": "4821" }
                                                                         │
                                                                         ▼
                                      privileged model or plain code (tools) ──▶ checks the values, then acts
```

### 2. Verify signatures before anything else

Verify the webhook or A2A signature over the raw body before parsing it, with the verifier of a Relay SDK, and drop anything that does not verify. Never act on an unsigned header. See [Webhooks](/guide/webhooks) for code in every SDK language.

### 3. Ask for authorisation before every action

Before an agent does something that matters (pays, deletes, sends on someone's behalf, changes access), it asks Access for an authorisation decision for that specific action. A response collected by Relay, however convincing, is evidence for that decision, never a substitute for it.

### 4. Never combine all three

An agent context must never hold all three of these at once:

1. the ability to call outside systems or send data out,
2. untrusted content,
3. private data.

Any two can be made safe; all three together let a crafted message exfiltrate private data. Split the work across contexts so that no single one has all three.

## Checklist

- Untrusted text from Relay is only ever read by a context without tools or secrets.
- Only typed values cross from that context to the one that acts.
- Every webhook and A2A message is verified over its raw body before parsing.
- Every consequential action gets an Access authorisation decision first.
- No context combines outside calls, untrusted content and private data.
- Mailbox records are handled once by id and acknowledged only after they are handled.
