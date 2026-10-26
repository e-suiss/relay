defmodule Relay.Delivery.DeadLetters do
  @moduledoc """
  The classified dead letter table and its replay rules (T-29). A dead letter is a record, never pruned: tenant, channel, provider, class (`permanent`, `quality_alarm`, `exhausted`, `budget_denied`), provider code, attempt count and times, and the recipient's blind index instead of personal data. A delivery has at most one open dead letter.

  Replay rules: a dead letter whose failure invalidated the target is never replayed and closes as `not_replayable`; `permanent` needs the reference of the fixed cause and `quality_alarm` a human approval; a record past its useful life closes as `expired`; a replayed delivery is not replayed again (depth at most 1). A replay is a new production, not a copy: its attempt carries a new provider idempotency key derived from the original key and the dead letter (`replay_key/2`), and its job runs in the low-concurrency `dlq_replay` queue. When a provider's circuit breaker closes, its `exhausted` dead letters of the last 30 minutes are replayed automatically (`Relay.Delivery.DeadLetters.AutoReplay`).
  """

  @auto_replay_window_ms 30 * 60_000

  # T-29 (5)
  @doc """
  Derives the provider idempotency key of a replay: `"rpl_"` and the lower-case hex of the first 16 bytes of SHA-256 over the deterministic CBOR of `["relay.replay.v1", original key, dead letter id]`. The same dead letter always derives the same key.
  """
  @spec replay_key(String.t() | nil, Relay.Id.t()) :: String.t()
  def replay_key(original_key, dead_letter_id)
      when is_nil(original_key) or is_binary(original_key) do
    input = ["relay.replay.v1", original_key, Relay.Id.to_string(dead_letter_id)]
    <<prefix::binary-16, _rest::binary>> = :crypto.hash(:sha256, Relay.Canonical.encode!(input))
    "rpl_" <> Base.encode16(prefix, case: :lower)
  end

  # T-29 (6)
  @doc "How far back a closed provider breaker replays `exhausted` dead letters: 30 minutes."
  @spec auto_replay_window_ms() :: pos_integer()
  def auto_replay_window_ms, do: @auto_replay_window_ms

  # T-29 (1)
  @doc "Returns whether a failure class invalidates its target, so its dead letter is never replayed."
  @spec invalidates_target?(String.t() | atom()) :: boolean()
  def invalidates_target?(failure_class), do: to_string(failure_class) == "permanent_target"
end
