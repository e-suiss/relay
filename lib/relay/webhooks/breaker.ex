defmodule Relay.Webhooks.Breaker do
  @moduledoc """
  The circuit breaker of one endpoint as a pure state machine (WH-35). The caller keeps the state with the endpoint, passes the time in milliseconds and the thresholds, and stores what comes back; nothing here reads a clock.

  | State | Event | Condition | New state |
  |---|---|---|---|
  | closed | failure | fewer than `failure_threshold` in a row | closed |
  | closed | failure | `failure_threshold` in a row | open for `open_ms` |
  | closed | success | — | closed, the count starts again |
  | open | admit | before the open time ends | open (reject) |
  | open | admit | the open time has ended | half-open, one probe |
  | half-open | admit | the probe is still out | half-open (reject) |
  | half-open | probe success | — | closed, everything reset |
  | half-open | probe failure | — | open again, for twice as long, at most `max_open_ms` |

  A failure is a failed or timed out attempt, as `Relay.Webhooks.Outcome` reports it. A rejected admission makes no attempt: the event waits, the attempt counter of its message does not move, and only the window of the event keeps running (WH-35 (2), (3)). A probe that never reports back stops blocking after `probe_ms`.

  It follows the shape of the provider breaker of the channel layer (`admit`, then `record` with the decision that was given) but not its rule: that one opens on a weighted failure ratio over a sliding window and keeps its state per node, this one opens on consecutive failures and doubles its open time, per endpoint.
  """

  defstruct state: :closed, failures: 0, open_count: 0, open_until: nil, probe_until: nil

  @type state :: :closed | :open | :half_open
  @type decision :: :allow | :probe | {:reject, non_neg_integer()}
  @type params :: %{
          failure_threshold: pos_integer(),
          open_ms: pos_integer(),
          max_open_ms: pos_integer(),
          probe_ms: pos_integer()
        }
  @type t :: %__MODULE__{
          state: state(),
          failures: non_neg_integer(),
          open_count: non_neg_integer(),
          open_until: integer() | nil,
          probe_until: integer() | nil
        }

  @states %{"closed" => :closed, "open" => :open, "half_open" => :half_open}

  @doc "A closed breaker."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # WH-35 (2)
  @doc "Admits an attempt at `now`: `:allow`, `:probe` (the one attempt of a half-open breaker) or `{:reject, wait_ms}` with the time after which to ask again."
  @spec admit(t(), integer(), params()) :: {decision(), t()}
  def admit(%__MODULE__{state: :closed} = breaker, _now, _params), do: {:allow, breaker}

  def admit(%__MODULE__{state: :open, open_until: open_until} = breaker, now, _params)
      when now < open_until,
      do: {{:reject, open_until - now}, breaker}

  def admit(%__MODULE__{state: :half_open, probe_until: probe_until} = breaker, now, _params)
      when now < probe_until,
      do: {{:reject, probe_until - now}, breaker}

  def admit(%__MODULE__{} = breaker, now, %{probe_ms: probe_ms}),
    do: {:probe, %{breaker | state: :half_open, probe_until: now + probe_ms}}

  # WH-35 (1)
  @doc "Records the result of an attempt that was admitted with `decision`. A result that arrives after the breaker moved on changes nothing."
  @spec record(t(), integer(), params(), :allow | :probe, :success | :failure) :: t()
  def record(%__MODULE__{state: :closed} = breaker, _now, _params, :allow, :success),
    do: %{breaker | failures: 0}

  def record(%__MODULE__{state: :closed} = breaker, now, params, :allow, :failure) do
    failures = breaker.failures + 1

    if failures >= params.failure_threshold,
      do: open(breaker, now, params),
      else: %{breaker | failures: failures}
  end

  def record(%__MODULE__{state: :half_open}, _now, _params, :probe, :success), do: new()

  def record(%__MODULE__{state: :half_open} = breaker, now, params, :probe, :failure),
    do: open(breaker, now, params)

  def record(%__MODULE__{} = breaker, _now, _params, decision, result)
      when decision in [:allow, :probe] and result in [:success, :failure],
      do: breaker

  defp open(breaker, now, params) do
    count = breaker.open_count + 1

    %__MODULE__{
      state: :open,
      open_count: count,
      open_until: now + open_ms(count, params)
    }
  end

  # WH-35
  @doc "The open time of the `count`-th opening in a row: `open_ms`, doubled on each reopening, at most `max_open_ms`."
  @spec open_ms(pos_integer(), params()) :: pos_integer()
  def open_ms(count, %{open_ms: open_ms, max_open_ms: max_open_ms})
      when is_integer(count) and count >= 1 do
    if count > 32, do: max_open_ms, else: min(max_open_ms, open_ms * Integer.pow(2, count - 1))
  end

  @doc "The state as a map of plain values, for storage with the endpoint."
  @spec dump(t()) :: %{optional(String.t()) => String.t() | integer() | nil}
  def dump(%__MODULE__{} = breaker) do
    %{
      "state" => Atom.to_string(breaker.state),
      "failures" => breaker.failures,
      "open_count" => breaker.open_count,
      "open_until" => breaker.open_until,
      "probe_until" => breaker.probe_until
    }
  end

  @doc "Reads a stored state back; anything that is not a dumped state is `:error`."
  @spec load(term()) :: {:ok, t()} | :error
  def load(%{"state" => state, "failures" => failures, "open_count" => open_count} = stored)
      when is_map_key(@states, state) and is_integer(failures) and is_integer(open_count) do
    breaker = %__MODULE__{
      state: Map.fetch!(@states, state),
      failures: failures,
      open_count: open_count,
      open_until: Map.get(stored, "open_until"),
      probe_until: Map.get(stored, "probe_until")
    }

    if consistent?(breaker), do: {:ok, breaker}, else: :error
  end

  def load(_stored), do: :error

  defp consistent?(%__MODULE__{failures: failures, open_count: open_count} = breaker),
    do: failures >= 0 and open_count >= 0 and deadline?(breaker)

  defp deadline?(%__MODULE__{state: :closed}), do: true
  defp deadline?(%__MODULE__{state: :open, open_until: until}), do: is_integer(until)
  defp deadline?(%__MODULE__{state: :half_open, probe_until: until}), do: is_integer(until)
end
