defmodule RelayDev.Reductions do
  @moduledoc """
  Reduction-count regression gate for pure core functions. Reductions are deterministic for a given input and runtime, so the gate runs on every pull request without timing noise; wall-clock benchmarks run nightly on the dedicated machine.
  """

  @tolerance 0.05

  # T-68
  @doc "Measures the reductions one call of `fun` takes, as the median of `runs` calls in a fresh process."
  @spec measure((-> term()), pos_integer()) :: non_neg_integer()
  def measure(fun, runs \\ 21) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_monitor(fn ->
        fun.()
        samples = for _ <- 1..runs, do: once(fun)
        send(parent, {ref, samples |> Enum.sort() |> Enum.at(div(runs, 2))})
      end)

    receive do
      {^ref, median} ->
        Process.demonitor(monitor, [:flush])
        median

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        raise "benchmark case crashed: #{inspect(reason)}"
    end
  end

  defp once(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, later} = Process.info(self(), :reductions)
    later - before
  end

  @doc "Compares measurements with the baseline; returns regressions beyond the tolerance and cases missing from the baseline."
  @spec compare(%{String.t() => non_neg_integer()}, %{String.t() => non_neg_integer()}) :: [
          String.t()
        ]
  def compare(measured, baseline) do
    Enum.flat_map(measured, fn {name, value} ->
      case Map.fetch(baseline, name) do
        :error ->
          ["#{name}: no baseline (run mix relay.bench.reductions --update)"]

        {:ok, base} when value > base * (1 + @tolerance) ->
          ["#{name}: #{value} reductions, baseline #{base}"]

        {:ok, _} ->
          []
      end
    end)
  end
end
