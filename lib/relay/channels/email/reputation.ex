defmodule Relay.Channels.Email.Reputation do
  @moduledoc """
  The pure state machine of the e-mail reputation circuit (CH-41), one per tenant × sending domain (and tenant × channel), on wall-clock milliseconds with the `reputation` parameters of the `email_reputation` data set. The bounce rate is bounces over sent mail and the complaint rate complaints over mail delivered to the inbox (CH-37), both over a sliding window of equal buckets.

  | State | Condition | New state | Transition |
  |---|---|---|---|
  | ok | a rate at its warning threshold | warning | `{:warning, rates}`: an event to the tenant |
  | ok, warning | a rate at its stop threshold | stopped | `{:stopped, rates}`: the stream pauses |
  | warning | both rates under their warning thresholds | ok | — |
  | stopped | any | stopped | — |

  A stopped circuit never closes by itself, however the rates fall: only `close/3`, an explicit tenant or operator action, closes it, clears the window and returns the audit record to write.
  """

  defstruct state: :ok, buckets: %{}, stopped_at: nil, stop_rates: nil

  @type state :: :ok | :warning | :stopped
  @type event :: :sent | :delivered | :bounce | :complaint
  @type rates :: %{
          sent: non_neg_integer(),
          delivered: non_neg_integer(),
          bounces: non_neg_integer(),
          complaints: non_neg_integer(),
          bounce_bp: non_neg_integer(),
          complaint_bp: non_neg_integer()
        }
  @type transition :: {:warning, rates()} | {:stopped, rates()}
  @type counts ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type t :: %__MODULE__{
          state: state(),
          buckets: %{integer() => counts()},
          stopped_at: integer() | nil,
          stop_rates: rates() | nil
        }

  @doc "A closed circuit with an empty window."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # CH-41
  @doc "Records `count` events at `now` and returns the circuit with the transitions the record caused."
  @spec record(t(), event(), integer(), map(), pos_integer()) :: {t(), [transition()]}
  def record(%__MODULE__{} = circuit, event, now, params, count \\ 1)
      when event in [:sent, :delivered, :bounce, :complaint] and is_integer(now) and count > 0 do
    index = div(now, bucket_ms(params))
    first = add(zero(), event, count)

    buckets =
      circuit.buckets
      |> prune(index, params)
      |> Map.update(index, first, &add(&1, event, count))

    circuit = %{circuit | buckets: buckets}

    if circuit.state == :stopped, do: {circuit, []}, else: evaluate(circuit, now, params)
  end

  defp evaluate(circuit, now, params) do
    rates = rates(circuit, now, params)

    cond do
      over?(rates, params["stop_bounce_bp"], params["stop_complaint_bp"]) ->
        {%{circuit | state: :stopped, stopped_at: now, stop_rates: rates}, [{:stopped, rates}]}

      over?(rates, params["warn_bounce_bp"], params["warn_complaint_bp"]) ->
        if circuit.state == :ok,
          do: {%{circuit | state: :warning}, [{:warning, rates}]},
          else: {circuit, []}

      true ->
        {%{circuit | state: :ok}, []}
    end
  end

  defp over?(rates, bounce_bp, complaint_bp) do
    (rates.sent > 0 and rates.bounces * 10_000 >= bounce_bp * rates.sent) or
      (rates.delivered > 0 and rates.complaints * 10_000 >= complaint_bp * rates.delivered)
  end

  # CH-41
  # CH-37
  @doc "The counts and rates, in basis points rounded down, of the window that ends at `now`."
  @spec rates(t(), integer(), map()) :: rates()
  def rates(%__MODULE__{buckets: buckets}, now, params) do
    current = buckets |> prune(div(now, bucket_ms(params)), params) |> Map.values()

    {sent, delivered, bounces, complaints} =
      Enum.reduce(current, zero(), fn {s, d, b, c}, {ts, td, tb, tc} ->
        {ts + s, td + d, tb + b, tc + c}
      end)

    %{
      sent: sent,
      delivered: delivered,
      bounces: bounces,
      complaints: complaints,
      bounce_bp: bp(bounces, sent),
      complaint_bp: bp(complaints, delivered)
    }
  end

  # CH-41
  @doc "Whether the stream may send: `:paused` while the circuit is stopped."
  @spec admit(t()) :: :allow | :paused
  def admit(%__MODULE__{state: :stopped}), do: :paused
  def admit(%__MODULE__{}), do: :allow

  # CH-41
  @doc "Closes a stopped circuit by an explicit action: `action` carries `:actor_ref` and `:reason`. The window is cleared, and the audit record of the closing is returned."
  @spec close(t(), %{actor_ref: String.t(), reason: String.t()}, integer()) ::
          {:ok, t(), map()} | {:error, :not_stopped}
  def close(%__MODULE__{state: :stopped} = circuit, %{actor_ref: actor_ref, reason: reason}, now)
      when is_binary(actor_ref) and actor_ref != "" and is_binary(reason) and reason != "" do
    audit = %{
      action: "email_reputation.closed",
      actor_ref: actor_ref,
      reason: reason,
      stopped_at: circuit.stopped_at,
      closed_at: now,
      stop_rates: circuit.stop_rates
    }

    {:ok, new(), audit}
  end

  def close(%__MODULE__{}, _action, _now), do: {:error, :not_stopped}

  defp bucket_ms(%{"window_ms" => window_ms, "buckets" => buckets}),
    do: max(div(window_ms, buckets), 1)

  defp prune(buckets, index, %{"buckets" => count}),
    do: Map.filter(buckets, fn {i, _counts} -> i > index - count and i <= index end)

  defp zero, do: {0, 0, 0, 0}

  defp add({s, d, b, c}, :sent, n), do: {s + n, d, b, c}
  defp add({s, d, b, c}, :delivered, n), do: {s, d + n, b, c}
  defp add({s, d, b, c}, :bounce, n), do: {s, d, b + n, c}
  defp add({s, d, b, c}, :complaint, n), do: {s, d, b, c + n}

  defp bp(_count, 0), do: 0
  defp bp(count, total), do: div(count * 10_000, total)
end
