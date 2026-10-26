defmodule Relay.Delivery.RetryBudget do
  @moduledoc """
  The retry budget of a channel and provider account (T-27). Two sliding counters over the budget window count every attempt start and every start of a retry (attempt two or later). A new retry is allowed while it keeps retries at or below `max_ratio_bp` of all attempts, and always below the minimum floor `min_retries`; otherwise it is denied and the delivery goes to the dead letters as `budget_denied`.

  The counters are ephemeral state in `relay_queue.limiter_states`, written through `relay_fn.rl_counter` in their own short transaction under the scope of the account's owner (OP-74).
  """

  @type decision :: :allow | :deny

  # T-27
  @doc "Decides one more retry from the counts in the window: `retries < min_retries`, or `(retries + 1) · 10000 ≤ max_ratio_bp · (total + 1)`."
  @spec decide(non_neg_integer(), non_neg_integer(), map()) :: decision()
  def decide(retries, total, %{"max_ratio_bp" => ratio} = row)
      when is_integer(retries) and is_integer(total) do
    floor = row["min_retries"] || 0

    if retries < floor or (retries + 1) * 10_000 <= ratio * (total + 1),
      do: :allow,
      else: :deny
  end

  # T-27
  @doc "The counter keys of a channel and provider account: total attempts and retries."
  @spec keys(String.t() | atom(), Relay.Id.t() | nil) :: %{total: String.t(), retry: String.t()}
  def keys(channel, account_id) do
    parts = "#{channel}:#{account(account_id)}"
    %{total: "retry_budget.total:" <> parts, retry: "retry_budget.retry:" <> parts}
  end

  defp account(nil), do: "none"
  defp account(id), do: Relay.Id.to_string(id)

  # T-27
  @doc "Counts an attempt start in the budget window; run it in its own scoped transaction."
  @spec count(String.t() | atom(), Relay.Id.t() | nil, pos_integer(), pos_integer()) :: :ok
  def count(channel, account_id, attempt_no, window_ms) do
    keys = keys(channel, account_id)
    _ = counter(keys.total, window_ms, "incr", 1)
    if attempt_no >= 2, do: _ = counter(keys.retry, window_ms, "incr", 1)
    :ok
  end

  # T-27
  @doc "Reads both counters and decides one more retry; run it in its own scoped transaction."
  @spec check(String.t() | atom(), Relay.Id.t() | nil, map()) :: decision()
  def check(channel, account_id, %{"window_ms" => window_ms} = row) do
    keys = keys(channel, account_id)
    total = counter(keys.total, window_ms, "read", 0)
    retries = counter(keys.retry, window_ms, "read", 0)
    decide(retries, total, row)
  end

  defp counter(key, window_ms, op, by),
    do: Relay.Delivery.Store.retry_counter(key, window_ms, op, by)
end
