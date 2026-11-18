# Migration guide

Moving notification traffic from an existing system to Relay is a change to something your users feel every day. The goal of this guide is a move in which no message is lost and no message is sent twice. It runs in five stages:

1. **Import** the address book, consent and suppressions.
2. **Shadow:** run Relay next to the old system without sending, and compare decisions.
3. **Staged rollout:** move users over in growing, sticky slices.
4. **Cutover:** hand over new work and scheduled jobs.
5. **Keep the old system warm** until the provider feedback windows have closed.

Some of the API operations named below are being introduced; until they appear in the [API reference](/reference/), treat their shape as described here, not as a contract.

## Import

Import runs as jobs. Start one with `POST /v1/imports` and an NDJSON upload, one record per line. Each job has one kind: `suppressions`, `consents`, `subscribers`, `devices`, `templates` or `scheduled`.

### Order matters, and Relay enforces it

1. Suppression lists, consents and opt-outs.
2. Device tokens and addresses.
3. Check that the suppressions now apply to the imported addresses, and that the counts match.
4. Only then change the send mode.

Relay refuses addresses and tokens for a tenant until its suppression and consent imports are complete, so an address can never be contacted before its opt-out has arrived.

### Rules for the data

- **Keep your identities.** The app bundle identifier, Apple team, Firebase project, WhatsApp business account, SMS sender name and sending domain stay the same; only the address book moves. Use a separate APNs key while both systems run.
- **Consent maps asymmetrically.** If any source says no, the answer is no. A yes counts only if it can be verified; in Türkiye that means it is registered in İYS. An unknown preference is never invented as yes or no: it is recorded as "migrated, unknown" in its origin field.
- **Tokens.** Clean out dead tokens before the import. A token and platform pair is unique; on a clash the most recently seen wins. If the source has no last-seen time, it stays empty and the import time is recorded separately. Tokens that cannot be moved are registered again by the app.
- **No automatic merging.** Two external ids with the same email or phone number are reported, not merged. Records with the same external id are merged. A device without an external id becomes an anonymous subscriber.
- **Provider ids are never keys.** A provider's internal id is kept in its own field for traceability, never as a primary key.
- **Normalise.** Phone numbers become E.164, languages become BCP 47 tags, broken character encodings are detected, and invalid records go to a separate bucket.
- **History.** Bring only the recent delivery history that frequency limits, deduplication and digests need. Leave the rest in your own archive.
- **Your processing.** An import is a data processing activity. Your processing agreement and any cross-border transfer assessment are yours to make; Relay gives you the metadata about where each provider processes data.

The result report gives counts, the invalid bucket and identity conflicts.

### Templates

Templates in Liquid or Handlebars are converted by parsing them into a syntax tree, never with regular expressions and never by guessing. Liquid is reduced to the subset Relay supports. Each template gets one of three verdicts:

- `AUTO_OK`: converted and equivalent;
- `NEEDS_REVIEW`: converted, but a person must check it;
- `CANNOT`: not converted; rewrite it by hand.

When variable names differ, you can add temporary aliases from old names to new ones. An alias lives for at most 90 days. HTTP calls made from inside a template are never carried over.

## Shadow mode

In shadow mode Relay runs the whole pipeline for real, including rate limits, concurrency and batching, but stops at the last step: it either does not call the provider at all, or calls only the provider's official validation mode (such as FCM's `validate_only`). Your users keep receiving the old system's messages, and a Relay error cannot affect them. Turn it on per tenant, category or channel with the send mode setting.

The old system reports its own decision for each request, as a digest, with `POST /v1/shadow/observations`. Relay records its own decision for the same request and compares the two:

- **decisions**, in full: who receives the message, on which channel, consent and suppression results, quiet hours, frequency limits and throttling, the deduplication key and timing;
- **content**, as a digest of a canonical form, with tracking pixels, signed links, one-time tokens, timestamps and ids masked (money and date formats are not masked, because a difference there is real);
- **routing**: provider and sender identity;
- **performance**.

Comparison records keep only masked and digested values, and are crypto-shredded after 14 days.

Outgoing webhooks are sent in shadow mode only to a separate endpoint you have marked as the shadow endpoint. Relay makes no call to the İYS API in shadow mode; it checks its local copy of the registry instead.

### Intentional differences

Before you start, write down where Relay is meant to behave differently from the old system. Each entry in the intentional differences list has an owner, a reason and an expiry of at most 30 days; renewing one is recorded in the audit log. The size of the list is itself a metric worth watching.

### When shadow mode is done

The exit is measured in coverage, not in days. The coverage report, in the API and the console, shows for each template, language and channel combination how often it was seen and whether the exit criteria are met:

- every active combination seen at least 100 times (a combination with less traffic counts when every example from two full business cycles has been compared);
- at least two full business cycles, and at least 14 days;
- zero decision differences that are not explained by an intentional difference.

### What shadow mode cannot tell you

Shadow mode measures agreement with the old system, not correctness. It cannot measure delivery rates, provider rejections, bounces and complaints, how users react, or latency under real load, because no real message is sent. The staged rollout measures those.

## Staged rollout

Rollout settings are per tenant: an emergency stop, a list of users always sent by Relay, a list always sent by the old system, the categories enabled for Relay, and for each category the share of users in basis points (1/100 of a percent).

### Sticky buckets

Traffic is split by user, never at random and never by channel or category alone. Each user falls into a bucket from 0 to 9,999: take the SHA-256 digest of the tenant id, a zero byte and the user's external id, read its first 8 bytes as an unsigned integer, and take the remainder after dividing by 10,000. Each request is then routed by the first rule that matches:

1. Emergency stop on: the old system.
2. User on the Relay list: Relay.
3. User on the old system's list: the old system.
4. Category not enabled: the old system.
5. Bucket below the category's share: Relay.
6. Anything else: the old system.

A request routed to the old system is recorded in Relay as `skipped` with the reason `routed_to_legacy`.

A user stays in the same bucket, so raising the share only adds users; nobody flips back and forth. Splitting by channel would break fallback chains, and splitting by category would break frequency limits and digests, so categories and channels only decide what is ready to move.

A settings change reaches every node within 60 seconds.

### Ramp rules

Relay checks each change of the share:

- a step may at most multiply the previous share by five;
- each step lasts at least one full day;
- the first step is at least 1%.

### When to stop

Watch these signals and act at the first threshold reached:

- **Duplicates**, measured from client telemetry: above 0.1% warn, above 0.5% freeze the rollout, above 1% roll back.
- **A message to a recipient without consent or with a suppression:** a single case means emergency stop.
- **Queue age:** if the oldest job in a lane stays above twice its alert threshold for 10 minutes, freeze.
- **`5xx` responses** over 5 minutes: above 1% freeze, above 5% roll back.
- **Acceptance or delivery rate per channel**, compared with the old system over an hour: a relative drop of 20% freezes, 40% rolls back.

Freezing means holding the share where it is. Rolling back means lowering the share, which takes effect within a minute without a deployment.

### Emergency stop

The emergency stop sends all of a tenant's traffic back to the old system. It is one command line call or one API call, by one person, and it opens an incident record automatically.

## Never send twice

Sending the same notification from both systems is a defect, not an accident of migration.

- **Shared deduplication claims.** Both systems derive the same deduplication key from the same rule. Before the old system sends, it claims the key with `POST /v1/dedup/claims`; Relay uses the same key for its own send, so whichever system claims first is the only one that sends.
- **One display point on the device.** Remove the old SDK's notification display code from your apps, so a device never shows a notification from both.
- **One write, then an outbox.** If you write to both systems during the move, write once and let an outbox deliver the second write. Two writes in a row in the same request drift apart silently when one fails.
- **Measure duplicates on the client.** The server cannot see duplicates that reached a device from two systems. The SDKs send a digest of each displayed notification's id, never its content, to Relay's telemetry endpoint, and the duplicate rate used by the rollout thresholds comes from there.

## Cutover

Cutover switches where new work is accepted. Work already in flight drains in the old system, and no job is ever owned by both.

### Scheduled messages

In order of preference:

1. Cancel in the old system and create again in Relay.
2. Hand over to Relay with an import of kind `scheduled`, in the order "add first, then cancel": Relay confirms the record, and only then the old system cancels it. Losing a message is worse than sending one twice.
3. Let the old system drain its own schedule.

Freeze scheduling in the old system ahead of the cutover by at least the furthest schedule horizon you use. A recipient with an open digest window is not imported until that window closes; the import report lists them.

### Recurring jobs

A recurring job is handed over with one atomic API call, so there is never a moment when it is active in both systems. Its last run, next run and cursor move with it, and its first run in Relay is a `dry_run` that you watch before it sends for real.

### Keep the old receivers open

Providers keep sending delivery receipts and bounces for messages the old system sent, sometimes for days. Keep the old system's webhook receivers open for the whole of those windows.

### Keep the old system warm

Keep the old system as a warm standby for a while after cutover. How long is your decision; we recommend at least until the longest provider receipt and bounce window has passed and one full business cycle has run cleanly on Relay.
