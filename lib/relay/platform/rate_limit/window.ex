defmodule Relay.Platform.RateLimit.Window do
  @moduledoc """
  The pure window cores, the reference for `priv/valkey/window.lua` and `relay_private.rl_window_at` / `rl_counter_at` (T-19):

  * `:fixed_window` counts in `W`-long windows shifted by the key's offset (`w = floor((t + offset) / W)`); it is for long coarse quotas only, because a short fixed window lets two bursts meet at its edge.
  * `:sliding_counter` weights the previous window by the part of it still inside the last `W` and allows only `L_eff = floor(0.90 * L)`, because the estimate errs towards allowing too much.
  * `:sliding_log` keeps every timestamp of the last `W`; it is exact and only for small `L` (at most 1000).

  Times are microseconds; windows, offsets and the returned `retry_after` are milliseconds. A denial leaves the state unchanged.
  """

  alias Relay.Platform.RateLimit.Gcra

  import Integer, only: [floor_div: 2]

  @type algorithm :: :fixed_window | :sliding_counter | :sliding_log
  @type counter :: %{w: integer(), c: non_neg_integer(), p: non_neg_integer()} | nil
  @type log :: [integer()]
  @type params :: %{
          limit: pos_integer(),
          window_ms: pos_integer(),
          offset_ms: non_neg_integer(),
          cost: pos_integer()
        }
  @type decision :: {:allowed | :limited, non_neg_integer(), non_neg_integer()}

  # T-19
  @doc "Decides one request at `now_us`; returns `{{code, count_after, retry_after_ms}, state}`."
  @spec step(algorithm(), counter() | log() | nil, params(), integer()) ::
          {decision(), counter() | log()}
  def step(:sliding_log, log, %{limit: l, window_ms: wms, cost: cost}, now_us) do
    window = wms * 1000
    log = log |> List.wrap() |> Enum.filter(&(&1 > now_us - window)) |> Enum.sort()
    count = length(log)

    cond do
      count + cost <= l ->
        {{:allowed, count + cost, 0}, Enum.sort(log ++ List.duplicate(now_us, cost))}

      cost > l ->
        {{:limited, count, Gcra.ceil_div(window, 1000)}, log}

      true ->
        first = Enum.at(log, count + cost - l - 1)
        {{:limited, count, max(1, Gcra.ceil_div(first + window - now_us, 1000))}, log}
    end
  end

  def step(:fixed_window, state, %{limit: l, window_ms: wms, offset_ms: oms, cost: cost}, now_us) do
    {window, offset} = {wms * 1000, oms * 1000}
    {w, cur, _prev, _est} = Gcra.window(state, now_us + offset, window)
    window_end = (w + 1) * window - offset

    if cur + cost <= l,
      do: {{:allowed, cur + cost, 0}, %{w: w, c: cur + cost, p: 0}},
      else: {{:limited, cur, Gcra.ceil_div(window_end - now_us, 1000)}, state}
  end

  def step(:sliding_counter, state, %{limit: l, window_ms: wms, offset_ms: oms, cost: cost}, now) do
    {window, offset} = {wms * 1000, oms * 1000}
    {w, cur, prev, est} = Gcra.window(state, now + offset, window)
    effective = effective_limit(l)

    cond do
      est + cost <= effective ->
        {{:allowed, est + cost, 0}, %{w: w, c: cur + cost, p: prev}}

      cur + cost > effective ->
        {{:limited, est, Gcra.ceil_div((w + 1) * window - offset - now, 1000)}, state}

      true ->
        first = w * window - offset + window - floor_div((effective - cur - cost) * window, prev)
        {{:limited, est, Gcra.ceil_div(first - now, 1000)}, state}
    end
  end

  # T-19
  @doc "The sliding counter's effective limit, `floor(0.90 * L)`."
  @spec effective_limit(pos_integer()) :: non_neg_integer()
  def effective_limit(limit), do: div(9 * limit, 10)

  # T-27
  @doc "A sliding counter without a limit: `:incr` adds `by` and returns the estimate after it, `:read` returns the estimate without writing. The window has no offset."
  @spec counter(:incr | :read, counter(), pos_integer(), non_neg_integer(), integer()) ::
          {non_neg_integer(), counter()}
  def counter(op, state, window_ms, by, now_us) do
    {w, cur, prev, est} = Gcra.window(state, now_us, window_ms * 1000)

    case op do
      :read -> {est, state}
      :incr -> {est + by, %{w: w, c: cur + by, p: prev}}
    end
  end
end
