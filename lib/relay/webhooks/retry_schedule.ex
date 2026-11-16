defmodule Relay.Webhooks.RetrySchedule do
  @moduledoc """
  The retry schedule of a message (WH-22, WH-25). The module is pure.

  A schedule is the list of waits, in milliseconds, before each attempt: its length is the number of attempts and its sum the retry window. It is a finite list, so a schedule without an end cannot be written down. `standard/0` is the schedule of the profile: ten attempts over about 76 hours.

  Every wait carries jitter of plus or minus `jitter_bp` basis points. The jitter is not random: it derives from the message id and the attempt number through `Relay.Jitter`, so the same message always gets the same times.

  `after_failure/5` decides what follows a failed attempt. A `Retry-After` of the consumer wins when it is longer than the wait of the schedule; such a deferral does not count as an attempt, is granted at most `max_deferrals` times for one message and after that the schedule runs as if the header were absent. The caller decides which responses carry a usable `Retry-After` (429 and 503).
  """

  @standard [
    0,
    5_000,
    300_000,
    1_800_000,
    7_200_000,
    18_000_000,
    36_000_000,
    50_400_000,
    72_000_000,
    86_400_000
  ]

  @type t :: [non_neg_integer(), ...]
  @type bounds :: %{
          min_attempts: pos_integer(),
          max_attempts: pos_integer(),
          min_total_ms: non_neg_integer(),
          max_total_ms: pos_integer(),
          min_wait_ms: non_neg_integer(),
          max_wait_ms: pos_integer()
        }
  @type progress :: %{attempts: non_neg_integer(), deferrals: non_neg_integer()}
  @type option ::
          {:jitter_bp, 0..10_000}
          | {:max_deferrals, non_neg_integer()}
          | {:retry_after_ms, non_neg_integer() | nil}
          | {:max_retry_after_ms, pos_integer() | nil}
  @type violation ::
          :invalid_schedule
          | :attempts_out_of_bounds
          | :wait_out_of_bounds
          | :window_out_of_bounds

  # WH-22 (1)
  @doc "The schedule of the profile: at once, 5 s, 5 min, 30 min, 2 h, 5 h, 10 h, 14 h, 20 h, 24 h."
  @spec standard() :: t()
  def standard, do: @standard

  @doc "The number of attempts of a schedule."
  @spec attempts(t()) :: pos_integer()
  def attempts([_first | _rest] = waits), do: length(waits)

  @doc "The retry window of a schedule without jitter: the sum of its waits."
  @spec total_window_ms(t()) :: non_neg_integer()
  def total_window_ms([_first | _rest] = waits), do: sum(waits, 0)

  # WH-22 (2)
  @doc "The longest the retry window can be once every wait carries its largest jitter."
  @spec longest_window_ms(t(), 0..10_000) :: non_neg_integer()
  def longest_window_ms([_first | _rest] = waits, jitter_bp) when jitter_bp in 0..10_000,
    do: sum(Enum.map(waits, &(&1 + spread(&1, jitter_bp))), 0)

  defp sum([], total), do: total
  defp sum([wait | rest], total) when is_integer(wait), do: sum(rest, total + wait)

  # WH-22 (3)
  @doc """
  Validates a schedule a tenant supplied against the bounds the caller passes: the number of attempts, the retry window and every wait but the first lie inside their bounds; the first wait may be zero and is at most the longest wait allowed.
  """
  @spec validate(term(), bounds()) :: {:ok, t()} | {:error, violation()}
  def validate(waits, bounds) when is_map(bounds) do
    with :ok <- shape(waits),
         :ok <- within(length(waits), bounds.min_attempts, bounds.max_attempts, :attempts),
         :ok <- waits_within(waits, bounds),
         :ok <- within(sum(waits, 0), bounds.min_total_ms, bounds.max_total_ms, :window) do
      {:ok, waits}
    end
  end

  defp shape([_first | _rest] = waits) do
    if Enum.all?(waits, &(is_integer(&1) and &1 >= 0)), do: :ok, else: {:error, :invalid_schedule}
  end

  defp shape(_waits), do: {:error, :invalid_schedule}

  defp within(value, low, high, _what) when value >= low and value <= high, do: :ok
  defp within(_value, _low, _high, :attempts), do: {:error, :attempts_out_of_bounds}
  defp within(_value, _low, _high, :window), do: {:error, :window_out_of_bounds}

  defp waits_within([first | rest], %{min_wait_ms: low, max_wait_ms: high}) do
    if first <= high and Enum.all?(rest, &(&1 >= low and &1 <= high)),
      do: :ok,
      else: {:error, :wait_out_of_bounds}
  end

  # WH-22 (2)
  @doc "The wait before attempt number `attempt` (from 1) of a message, with its jitter, or `:exhausted` when the schedule has no such attempt."
  @spec wait_ms(t(), pos_integer(), Relay.Id.t(), 0..10_000) ::
          {:ok, non_neg_integer()} | :exhausted
  def wait_ms(waits, attempt, message_id, jitter_bp)
      when is_list(waits) and is_integer(attempt) and attempt >= 1 and jitter_bp in 0..10_000 do
    case Enum.fetch(waits, attempt - 1) do
      {:ok, wait} -> {:ok, jittered(wait, attempt, message_id, jitter_bp)}
      :error -> :exhausted
    end
  end

  # WH-22
  @doc "The time of the attempt that follows `attempts_made` counted attempts, measured from `from`: the creation of the message for the first attempt, the end of the last attempt afterwards."
  @spec next_attempt_at(t(), non_neg_integer(), Relay.Id.t(), DateTime.t(), 0..10_000) ::
          {:ok, DateTime.t()} | :exhausted
  def next_attempt_at(waits, attempts_made, message_id, %DateTime{} = from, jitter_bp)
      when is_integer(attempts_made) and attempts_made >= 0 do
    case wait_ms(waits, attempts_made + 1, message_id, jitter_bp) do
      {:ok, wait} -> {:ok, DateTime.add(from, wait, :millisecond)}
      :exhausted -> :exhausted
    end
  end

  # WH-25
  @doc """
  Decides what follows an attempt that failed and may be retried. `progress` is the state before that attempt: the attempts counted so far and the `Retry-After` deferrals granted so far.

  With a `:retry_after_ms` that is longer than the wait the schedule would apply now, and a deferral left, the message waits for `Retry-After`, the attempt is not counted and the result is tagged `:retry_after`. Otherwise the attempt is counted and the schedule gives the next time, tagged `:schedule`, or the message is `:exhausted`. A message can therefore be tried at most as often as the schedule has attempts plus `max_deferrals`.

  Options: `:jitter_bp` and `:max_deferrals` (required), `:retry_after_ms`, and `:max_retry_after_ms`, which caps what a consumer may ask for.
  """
  @spec after_failure(t(), progress(), Relay.Id.t(), DateTime.t(), [option()]) ::
          {:retry, DateTime.t(), progress(), :schedule | :retry_after} | {:exhausted, progress()}
  def after_failure([_first | _rest] = waits, progress, id, %DateTime{} = now, opts)
      when is_list(opts) do
    %{attempts: attempts, deferrals: deferrals} = progress
    jitter_bp = Keyword.fetch!(opts, :jitter_bp)
    retry_after = retry_after(opts)
    deferrable = deferrals < Keyword.fetch!(opts, :max_deferrals)
    scheduled = wait_ms(waits, attempts + 2, id, jitter_bp)

    if deferrable and longer?(retry_after, scheduled) do
      at = DateTime.add(now, retry_after, :millisecond)
      {:retry, at, %{progress | deferrals: deferrals + 1}, :retry_after}
    else
      counted(waits, %{progress | attempts: attempts + 1}, id, now, jitter_bp)
    end
  end

  defp retry_after(opts) do
    case {Keyword.get(opts, :retry_after_ms), Keyword.get(opts, :max_retry_after_ms)} do
      {wait, cap} when is_integer(wait) and is_integer(cap) -> min(max(wait, 0), cap)
      {wait, _cap} when is_integer(wait) -> max(wait, 0)
      {_wait, _cap} -> nil
    end
  end

  defp longer?(nil, _scheduled), do: false
  defp longer?(_retry_after, :exhausted), do: true
  defp longer?(retry_after, {:ok, wait}), do: retry_after > wait

  defp counted(waits, progress, id, now, jitter_bp) do
    case next_attempt_at(waits, progress.attempts, id, now, jitter_bp) do
      {:ok, at} -> {:retry, at, progress, :schedule}
      :exhausted -> {:exhausted, progress}
    end
  end

  defp jittered(0, _attempt, _message_id, _jitter_bp), do: 0

  defp jittered(wait, attempt, message_id, jitter_bp) do
    spread = spread(wait, jitter_bp)
    digest = Relay.Jitter.h("webhook_retry", [Relay.Id.to_string(message_id), attempt])
    wait - spread + Relay.Jitter.scale(digest, 2 * spread + 1)
  end

  defp spread(wait, jitter_bp), do: div(wait * jitter_bp, 10_000)
end
