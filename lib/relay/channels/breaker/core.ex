defmodule Relay.Channels.Breaker.Core do
  @moduledoc """
  The pure state machine of a circuit breaker (T-25), on monotonic milliseconds (T-11). The node-local breaker (`Relay.Channels.Breaker`) keeps the same state in `:atomics` and decides with the predicates of this module; the struct here is the reference the state table is tested against.

  | State | Event | Condition | New state |
  |---|---|---|---|
  | closed | result | `calls ≥ min_throughput` and weighted failure ratio `≥ failure_ratio_bp` | open |
  | closed | result | `p99_latency_ms` set, `calls ≥ min_throughput` and more than 1 % of the calls slower than it | open |
  | open | admit | `now < open_until` | open (reject) |
  | open | admit | `now ≥ open_until` | half_open |
  | half_open | admit | fewer than `half_open_probes` probes in flight | probe |
  | half_open | admit | otherwise | reject |
  | half_open | probe success | `half_open_successes` consecutive successes | closed, window cleared |
  | half_open | probe failure (weight > 0) | — | open (`open_count + 1`) |

  The window is a ring of ten buckets of `window_ms / 10`. A failure adds its class weight (1000 = 1.0) to the bucket's score; a class of weight 0, an application rejection such as an invalid token or number, counts as a call and never opens the breaker (T-25 (4), CH-15). The open time carries deterministic jitter per node and opening (`Relay.Jitter.breaker_open/5`, T-25 (6)).
  """

  @buckets 10

  defstruct state: :closed,
            opened_at: nil,
            open_until: nil,
            open_count: 0,
            probes: 0,
            successes: 0,
            window: %{}

  @type state :: :closed | :open | :half_open
  @type decision :: :allow | :probe | {:reject, non_neg_integer()}
  @type t :: %__MODULE__{
          state: state(),
          opened_at: integer() | nil,
          open_until: integer() | nil,
          open_count: non_neg_integer(),
          probes: non_neg_integer(),
          successes: non_neg_integer(),
          window: %{integer() => {non_neg_integer(), non_neg_integer(), non_neg_integer()}}
        }

  @doc "The number of window buckets."
  @spec buckets() :: pos_integer()
  def buckets, do: @buckets

  # T-25 (3)
  @doc "The length of one window bucket in milliseconds."
  @spec bucket_ms(map()) :: pos_integer()
  def bucket_ms(%{"window_ms" => window_ms}), do: max(div(window_ms, @buckets), 1)

  # T-25 (3)
  # T-25 (5)
  @doc "Whether window counts open a closed breaker: enough calls, and a weighted failure ratio at the threshold or slow calls over the latency threshold."
  @spec trip?(non_neg_integer(), non_neg_integer(), non_neg_integer(), map()) :: boolean()
  def trip?(calls, score_milli, slow_calls, row) do
    calls >= row["min_throughput"] and
      (score_milli * 10 >= row["failure_ratio_bp"] * calls or
         (row["p99_latency_ms"] != nil and slow_calls * 100 > calls))
  end

  # T-25 (5)
  @doc "Whether a call of `latency_ms` counts as slow under the latency threshold."
  @spec slow?(map(), non_neg_integer() | nil) :: boolean()
  def slow?(%{"p99_latency_ms" => threshold}, latency_ms)
      when is_integer(threshold) and is_integer(latency_ms),
      do: latency_ms > threshold

  def slow?(_row, _latency_ms), do: false

  # T-25 (6)
  @doc "The end of the `open_count`-th opening on this node, opened at `now`."
  @spec open_until(integer(), pos_integer(), map(), String.t(), String.t()) :: integer()
  def open_until(now, open_count, row, node_name, key) when is_integer(now) do
    now +
      Relay.Jitter.breaker_open(node_name, key, open_count, row["open_ms"], row["open_jitter_bp"])
  end

  # T-25 (2)
  @doc "Whether consecutive probe successes close a half-open breaker."
  @spec closes?(non_neg_integer(), map()) :: boolean()
  def closes?(successes, row), do: successes >= row["half_open_successes"]

  # T-25 (2)
  @doc "Whether another probe may run while `probes` are in flight."
  @spec probe?(non_neg_integer(), map()) :: boolean()
  def probe?(probes, row), do: probes < row["half_open_probes"]

  @doc "A closed breaker with an empty window."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # T-25 (2)
  @doc "Admits a call at `now`: `:allow`, `:probe` or `{:reject, retry_after_ms}`."
  @spec admit(t(), integer(), map()) :: {decision(), t()}
  def admit(%__MODULE__{state: :closed} = b, _now, _row), do: {:allow, b}

  def admit(%__MODULE__{state: :open, open_until: until} = b, now, _row) when now < until,
    do: {{:reject, until - now}, b}

  def admit(%__MODULE__{state: :open} = b, now, row),
    do: admit(%{b | state: :half_open}, now, row)

  def admit(%__MODULE__{state: :half_open} = b, _now, row) do
    if probe?(b.probes, row),
      do: {:probe, %{b | probes: b.probes + 1}},
      else: {{:reject, bucket_ms(row)}, b}
  end

  # T-25
  @doc """
  Records the result of an admitted call at `now`: `weight` is the failure's class weight for this breaker's level (0 for a success or for a failure of the other level), `slow?` whether the call exceeded the latency threshold.
  """
  @spec record(
          t(),
          integer(),
          map(),
          :allow | :probe,
          non_neg_integer(),
          boolean(),
          {String.t(), String.t()}
        ) ::
          t()
  def record(%__MODULE__{state: :half_open} = b, now, row, :probe, weight, _slow?, jitter) do
    b = %{b | probes: max(b.probes - 1, 0)}

    cond do
      weight > 0 -> open(b, now, row, jitter)
      closes?(b.successes + 1, row) -> %__MODULE__{}
      true -> %{b | successes: b.successes + 1}
    end
  end

  def record(%__MODULE__{state: :closed} = b, now, row, :allow, weight, slow?, jitter) do
    b = %{b | window: add(b.window, div_floor(now, bucket_ms(row)), weight, slow?)}
    {calls, score, slow} = counts(b.window, div_floor(now, bucket_ms(row)))

    if trip?(calls, score, slow, row), do: open(b, now, row, jitter), else: b
  end

  def record(%__MODULE__{} = b, _now, _row, _decision, _weight, _slow?, _jitter), do: b

  @doc "Sums the window counts of the buckets inside the window that ends in bucket `current`."
  @spec counts(map(), integer()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def counts(window, current) do
    for {bucket, {calls, score, slow}} <- window,
        bucket > current - @buckets,
        bucket <= current,
        reduce: {0, 0, 0} do
      {c, s, l} -> {c + calls, s + score, l + slow}
    end
  end

  defp add(window, bucket, weight, slow?) do
    window
    |> Map.reject(fn {b, _} -> b <= bucket - @buckets end)
    |> Map.update(bucket, {1, weight, slow_count(slow?)}, fn {c, s, l} ->
      {c + 1, s + weight, l + slow_count(slow?)}
    end)
  end

  defp open(b, now, row, {node_name, key}) do
    count = b.open_count + 1

    %{
      b
      | state: :open,
        opened_at: now,
        open_until: open_until(now, count, row, node_name, key),
        open_count: count,
        probes: 0,
        successes: 0,
        window: %{}
    }
  end

  defp slow_count(true), do: 1
  defp slow_count(false), do: 0

  @doc "Floor division of monotonic milliseconds into a bucket number."
  @spec div_floor(integer(), pos_integer()) :: integer()
  def div_floor(now, size), do: Integer.floor_div(now, size)
end
