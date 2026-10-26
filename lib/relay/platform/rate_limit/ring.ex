defmodule Relay.Platform.RateLimit.Ring do
  @moduledoc """
  The pure 120-minute bucket ring behind the dead man's switch counters (TN-43), the reference for `priv/valkey/rate_ring.lua` and `relay_private.rl_ring_at`. Each call adds its cost to the bucket of the current minute, forgets buckets older than 120 minutes and returns the sum of the last `current` minutes and of the `baseline` minutes before them. A clock that steps back keeps counting into the newest bucket.
  """

  import Integer, only: [floor_div: 2]

  @minute_us 60_000_000
  @size 120

  @type state :: %{integer() => non_neg_integer()}

  # TN-43
  @doc "Adds `cost` at `now_us` and returns `{{current_sum, baseline_sum}, state}`."
  @spec step(state(), non_neg_integer(), pos_integer(), non_neg_integer(), integer()) ::
          {{non_neg_integer(), non_neg_integer()}, state()}
  def step(state, cost, current, baseline, now_us)
      when current >= 1 and baseline >= 0 and current + baseline <= @size do
    state = state || %{}
    minute = Enum.max([floor_div(now_us, @minute_us) | Map.keys(state)])

    state =
      state
      |> Map.reject(fn {m, _} -> m <= minute - @size end)
      |> Map.update(minute, cost, &(&1 + cost))

    sum = fn from, to -> for({m, c} <- state, m > from and m <= to, do: c) |> Enum.sum() end
    {{sum.(minute - current, minute), sum.(minute - current - baseline, minute - current)}, state}
  end
end
