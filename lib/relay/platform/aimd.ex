defmodule Relay.Platform.Aimd do
  @moduledoc """
  The input rate ceiling of a bulk lane (T-35 (5), T-97), as pure functions. The ceiling adapts to the lane's queue depth once per capacity sample (every 5 s): above `0.8 · L_max` it is halved, below `0.5 · L_max` it grows by 5 % of the lane's service rate `μ`, in between it stays. It starts at `μ` and stays between `0.01 · μ` and `μ`, where `μ` is the measured or configured rate of `Relay.Platform.Capacity` and `L_max = μ · W_max`. A lane whose `μ` is unknown has no ceiling.

  Input above the ceiling is refused at the entrance with `429 rate_limited` and `Retry-After`. `admit/3` decides one request with Relay's GCRA arithmetic on a monotonic clock in microseconds: the emission interval is `1 / ceiling`, and up to one second of input (at least one request) may arrive at once.

  The values are an engineering assumption checked by the load test (T-89).
  """

  @high 0.8
  @low 0.5
  @decrease 0.5
  @increase 0.05
  @floor 0.01

  @type ceiling :: float()
  @type capacity :: {mu_per_s :: number(), w_max_ms :: pos_integer(), queued :: non_neg_integer()}

  # T-97
  @doc "The lane's ceiling after one sample: `previous` (`nil` before the first) moved by the queue depth of `capacity`; `nil` when `μ` is unknown."
  @spec step(ceiling() | nil, capacity() | nil) :: ceiling() | nil
  def step(previous, {mu, w_max_ms, queued})
      when is_number(mu) and mu > 0 and is_integer(w_max_ms) and is_integer(queued) do
    l_max = mu * w_max_ms / 1_000
    current = clamp(previous || mu, mu)

    next =
      cond do
        queued > @high * l_max -> current * @decrease
        queued < @low * l_max -> current + @increase * mu
        true -> current
      end

    clamp(next, mu)
  end

  def step(_previous, _capacity), do: nil

  # T-97
  @doc "The lowest ceiling of a lane with service rate `mu`."
  @spec lowest(number()) :: ceiling()
  def lowest(mu), do: mu * @floor

  defp clamp(ceiling, mu), do: ceiling |> max(lowest(mu)) |> min(mu * 1.0)

  # T-97
  # T-19
  @doc "Decides one request under `ceiling` requests per second, given the lane's theoretical arrival time `tat_us` (`nil` when none) at `now_us`: `{:allow, new_tat_us}` or `{:deny, retry_after_ms}`."
  @spec admit(ceiling(), integer() | nil, integer()) ::
          {:allow, integer()} | {:deny, pos_integer()}
  def admit(ceiling, tat_us, now_us) when is_number(ceiling) and ceiling > 0 do
    emission = max(round(1_000_000 / ceiling), 1)
    allowance = max(trunc(ceiling), 1) * emission
    start = max(tat_us || now_us, now_us)
    ahead = start + emission - now_us

    if ahead > allowance,
      do: {:deny, max(div(ahead - allowance + 999, 1_000), 1)},
      else: {:allow, start + emission}
  end
end
