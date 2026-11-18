# Why didn't they get it?

When a message is not sent, Relay says why. Every rule that skips, defers, expires, cancels or pauses a delivery writes a decision with a `rule_id` from one rule dictionary, the recorded detail the dictionary lists for that rule (for example, which preference level closed the channel) and a one-sentence explanation. Nothing is dropped silently.

## Read a subscriber's decisions

<<< @/examples/curl/decisions.sh

The answer covers the last 30 days by default, newest first. For each notification you get:

- `state`: `active`, `cancelled` or `expired`, and the `close_rule_id` that closed it, if any,
- for each delivery: the channel, its [status](./delivery-semantics#the-status-you-read), and `gates`, which is `passed` when every policy gate let it through, `stopped` when a rule skipped, expired or cancelled it, and `deferred` while a rule holds it,
- `decisions`: each recorded decision with `rule_id`, `outcome` (`skip`, `defer`, `expire`, `cancel`, `pause` or `reject`), `reason`, the dictionary's `detail` and `description` in English and Turkish.

No personal data appears in the answer. The console shows the same chain on its "Why didn't I receive" screen, where support staff look a person up by id, phone or email; contact details stay masked unless an operator with the right role reveals them, and every reveal is audited.

## The order rules run in

Every delivery passes the same three stages:

1. **Gates** are absolute: a suppression, a refusal, a missing commercial consent, a kill switch, a dead channel or a scope mismatch. No flag, category or request field gets past a gate.
2. **Filters** remove what the person or policy does not want: a preference turned off, no template variant for the channel, no consent.
3. **Shapers** decide when: quiet hours, delivery windows, frequency caps and throttles defer rather than drop.

Policy outcomes are decisions, not errors: the API accepted your request, and the decision is part of the record.
