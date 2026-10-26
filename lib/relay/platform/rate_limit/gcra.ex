defmodule Relay.Platform.RateLimit.Gcra do
  @moduledoc """
  The pure GCRA core, the reference the Valkey script `priv/valkey/gcra.lua` and the PostgreSQL function `relay_private.rl_gcra_at` must match on every vector of `test/vectors/rate_limit/gcra_v1.json`.

  Time is an integer of microseconds read once from the deciding backend; the node clock never enters a decision. The emission interval is `ceil(P / L)`, rounded up so Relay is stricter than the provider, and the stored theoretical arrival time is first pulled to `max(stored, now)`, so a clock that steps back cannot release capacity. A request whose cost exceeds the burst is never allowed. With a lane ceiling the same key also keeps a two-window sliding counter of the cumulative consumption of every lane; the GCRA and the counter are consumed together or not at all.
  """

  import Integer, only: [floor_div: 2]

  @type state :: %{tat: integer(), w: integer(), c: non_neg_integer(), p: non_neg_integer()} | nil
  @type params :: %{
          emission_us: pos_integer(),
          burst: pos_integer(),
          cost: pos_integer(),
          cap: integer(),
          limit: pos_integer(),
          period_us: pos_integer(),
          offset_us: non_neg_integer()
        }
  @type code :: :allowed | :limited | :ceiling | :cost_exceeds_burst
  @type outcome :: %{
          retry_after_us: non_neg_integer(),
          tat_us: integer(),
          now_us: integer(),
          estimate: non_neg_integer()
        }

  # T-19
  # T-20 (4)
  @doc "The emission interval in microseconds of `limit` requests per `period_ms`, rounded up."
  @spec emission_us(pos_integer(), pos_integer()) :: pos_integer()
  def emission_us(limit, period_ms)
      when is_integer(limit) and limit > 0 and is_integer(period_ms) and period_ms > 0,
      do: ceil_div(period_ms * 1000, limit)

  # T-11
  # T-19
  # T-33
  @doc "Decides one request at `now_us` and returns its code, outcome and the state to store; a denial returns the state unchanged."
  @spec step(state(), params(), integer()) :: {code(), outcome(), state()}
  def step(state, params, now_us) when is_integer(now_us) do
    %{emission_us: t, burst: b, cost: cost, cap: cap, limit: l, period_us: p, offset_us: off} =
      params

    tat0 = if state, do: state.tat, else: now_us
    {w, cur, prev, est} = window(state, now_us + off, p)
    outcome = %{retry_after_us: 0, tat_us: tat0, now_us: now_us, estimate: est}
    tat1 = max(tat0, now_us) + cost * t

    cond do
      cost > b ->
        {:cost_exceeds_burst, outcome, state}

      tat1 - now_us > b * t ->
        {:limited, %{outcome | retry_after_us: tat1 - now_us - b * t}, state}

      cap >= 0 and est + cost > cap ->
        retry = max(t, ceil_div((est + cost - cap) * p, l))
        {:ceiling, %{outcome | retry_after_us: retry}, state}

      true ->
        {:allowed, %{outcome | tat_us: tat1, estimate: est + cost},
         %{tat: tat1, w: w, c: cur + cost, p: prev}}
    end
  end

  # T-33
  @doc """
  Shifts a two-window counter to the window of position `x` (now plus the key's offset) and returns `{window, current, previous, estimate}`, where `estimate = ceil(previous * (P - e) / P) + current`. A stored window ahead of `x` is kept and read from its start, so a clock step back never forgets consumption.
  """
  @spec window(%{w: integer(), c: integer(), p: integer()} | nil, integer(), pos_integer()) ::
          {integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def window(state, x, period) do
    w = floor_div(x, period)
    pos = x - w * period

    {w, pos, cur, prev} =
      case state do
        nil -> {w, pos, 0, 0}
        %{w: sw, c: c, p: pr} when sw > w -> {sw, 0, c, pr}
        %{w: ^w, c: c, p: pr} -> {w, pos, c, pr}
        %{w: sw, c: c} when sw == w - 1 -> {w, pos, 0, c}
        _older -> {w, pos, 0, 0}
      end

    {w, cur, prev, ceil_div(prev * (period - pos), period) + cur}
  end

  @doc "Integer division rounded up."
  @spec ceil_div(integer(), pos_integer()) :: integer()
  def ceil_div(a, b), do: -floor_div(-a, b)
end
