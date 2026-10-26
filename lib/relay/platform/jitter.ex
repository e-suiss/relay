defmodule Relay.Platform.Jitter do
  @moduledoc """
  Deterministic digest and jitter. Every jitter, spread, canary bucket and window offset derives from one function: the first eight bytes, read as a big-endian unsigned integer, of SHA-256 over the deterministic CBOR (`Relay.Canonical`) of `["relay.jitter.v1", purpose, part_1, …, part_n]`. `scale/2` maps that digest onto `[0, n)`. Identifiers enter as lowercase canonical UUID text, environments as text and counters as CBOR integers, so the same inputs give the same result in every language and release. The module is pure; no random source is read.
  """

  @version "relay.jitter.v1"
  @two_64 18_446_744_073_709_551_616

  @type part :: Relay.Canonical.value()

  # T-30
  # T-91 (3)
  @doc "Returns the 64-bit digest of `purpose` and `parts`."
  @spec h(String.t(), [part()]) :: non_neg_integer()
  def h(purpose, parts) when is_binary(purpose) and is_list(parts) do
    <<value::unsigned-big-64, _rest::binary>> =
      :crypto.hash(:sha256, digest_input(purpose, parts))

    value
  end

  @doc "Returns the deterministic CBOR input that `h/2` hashes."
  @spec digest_input(String.t(), [part()]) :: binary()
  def digest_input(purpose, parts) when is_binary(purpose) and is_list(parts),
    do: Relay.Canonical.encode!([@version, purpose | parts])

  # T-30
  @doc "Scales a 64-bit digest onto `[0, n)` as `(h × n) div 2^64`."
  @spec scale(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def scale(h, n) when is_integer(h) and h >= 0 and h < @two_64 and is_integer(n) and n >= 1,
    do: div(h * n, @two_64)

  # T-26
  # T-30
  @doc "Full-jitter backoff after the `n`-th failed attempt of a delivery: `scale(h, min(cap_ms, base_ms · 2^(n−1)) + 1)`."
  @spec backoff(
          Relay.Id.t(),
          Relay.Environment.t(),
          Relay.Id.t(),
          pos_integer(),
          pos_integer(),
          pos_integer()
        ) ::
          non_neg_integer()
  def backoff(tenant_id, environment, delivery_id, n, base_ms, cap_ms)
      when is_integer(n) and n >= 1 and is_integer(base_ms) and base_ms >= 1 and
             is_integer(cap_ms) and cap_ms >= base_ms do
    digest = h("backoff", [id(tenant_id), env(environment), id(delivery_id), n])
    scale(digest, exponential(base_ms, n - 1, cap_ms) + 1)
  end

  # CH-9
  # T-30
  @doc "Wait after a provider `Retry-After` of `ra_ms` for the `n`-th failed attempt: `ra_ms + scale(h, floor(ra_ms / 5) + 1)`, so 0–20 % on top."
  @spec retry_after(
          Relay.Id.t(),
          Relay.Environment.t(),
          Relay.Id.t(),
          pos_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  def retry_after(tenant_id, environment, delivery_id, n, ra_ms)
      when is_integer(n) and n >= 1 and is_integer(ra_ms) and ra_ms >= 0 do
    digest = h("retry_after", [id(tenant_id), env(environment), id(delivery_id), n])
    ra_ms + scale(digest, div(ra_ms, 5) + 1)
  end

  # T-25 (6)
  # T-30
  @doc "Open time of a circuit breaker on a node for its `open_count`-th opening: `open_ms + scale(h, floor(open_ms · jitter_bp / 10000) + 1)`."
  @spec breaker_open(String.t(), String.t(), pos_integer(), pos_integer(), 0..10_000) ::
          pos_integer()
  def breaker_open(node_name, breaker_key, open_count, open_ms, jitter_bp)
      when is_binary(node_name) and is_binary(breaker_key) and is_integer(open_count) and
             open_count >= 1 and is_integer(open_ms) and open_ms >= 1 and is_integer(jitter_bp) and
             jitter_bp >= 0 and jitter_bp <= 10_000 do
    digest = h("breaker_open", [node_name, breaker_key, open_count])
    open_ms + scale(digest, div(open_ms * jitter_bp, 10_000) + 1)
  end

  # T-30
  @doc "Canary bucket of a notification, in `0..99`."
  @spec canary_bucket(Relay.Id.t(), Relay.Environment.t(), Relay.Id.t()) :: 0..99
  def canary_bucket(tenant_id, environment, notification_id),
    do: scale(h("canary", [id(tenant_id), env(environment), id(notification_id)]), 100)

  @doc "Returns true if the notification falls inside a canary of `canary_percent` percent."
  @spec canary?(Relay.Id.t(), Relay.Environment.t(), Relay.Id.t(), 0..100) :: boolean()
  def canary?(tenant_id, environment, notification_id, canary_percent)
      when is_integer(canary_percent) and canary_percent >= 0 and canary_percent <= 100,
      do: canary_bucket(tenant_id, environment, notification_id) < canary_percent

  # T-19
  # T-30
  @doc "Window offset of a limit key, in `[0, window_ms)`."
  @spec window_offset(String.t(), pos_integer()) :: non_neg_integer()
  def window_offset(limit_key, window_ms)
      when is_binary(limit_key) and is_integer(window_ms) and window_ms >= 1,
      do: scale(h("window_offset", [limit_key]), window_ms)

  # T-22
  # T-34 (4)
  # T-30
  @doc "Snooze of the `k`-th postponement of a job: `base_ms + scale(h, floor(base_ms / 5) + 1)`."
  @spec snooze(
          Relay.Id.t(),
          Relay.Environment.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  def snooze(tenant_id, environment, job_ref, k, base_ms)
      when is_binary(job_ref) and is_integer(k) and k >= 0 and is_integer(base_ms) and
             base_ms >= 0 do
    digest = h("snooze", [id(tenant_id), env(environment), job_ref, k])
    base_ms + scale(digest, div(base_ms, 5) + 1)
  end

  # T-30
  @doc "Backoff of a crashed job attempt: `scale(h, min(300000, 1000 · 2^attempt) + 1)`."
  @spec crash_backoff(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def crash_backoff(job_id, attempt)
      when is_integer(job_id) and job_id >= 0 and is_integer(attempt) and attempt >= 0,
      do: scale(h("crash_backoff", [job_id, attempt]), exponential(1_000, attempt, 300_000) + 1)

  defp exponential(base, exponent, cap) do
    if exponent >= 64, do: cap, else: min(cap, base * Integer.pow(2, exponent))
  end

  defp id(id), do: Relay.Id.to_string(id)

  defp env(environment), do: Relay.Environment.dump(environment)
end
