defmodule Relay.Platform.RateLimit.Store do
  @moduledoc """
  The PostgreSQL fallback of the limiters: `relay_fn.rl_gcra`, `rl_window`, `rl_counter` and `rl_ring` over `relay_queue.limiter_states`. Each call runs in its own short scoped transaction, because the decision's row lock lasts until commit; it is never part of another write. The decision time is the database's `clock_timestamp()`. A database failure is returned as an error, never as a decision.
  """

  alias Relay.Repo

  @type failure :: {:error, Relay.Error.t()}

  # T-20 (1)
  # T-11
  @doc "Runs the GCRA decision of `relay_fn.rl_gcra`; returns `{code, retry_after_us, tat_us, now_us}`."
  @spec gcra(Relay.Scope.t(), String.t(), map()) ::
          {:ok,
           {:allowed | :limited | :ceiling | :cost_exceeds_burst, non_neg_integer(), integer(),
            integer()}}
          | failure()
  def gcra(scope, limit_key, p) do
    call(scope, "relay_fn.rl_gcra", [
      limit_key,
      p.emission_us,
      p.burst,
      p.cost,
      p.cap,
      p.limit,
      p.period_us,
      p.offset_us
    ])
    |> one(fn row ->
      {Repo.code!(row["result"], [:allowed, :limited, :ceiling, :cost_exceeds_burst]),
       row["retry_after_us"], row["tat_us"], row["now_us"]}
    end)
  end

  # T-19
  @doc "Runs a window decision of `relay_fn.rl_window`; returns `{code, count_after, retry_after_ms}`."
  @spec window(Relay.Scope.t(), String.t(), atom(), map()) ::
          {:ok, {:allowed | :limited, non_neg_integer(), non_neg_integer()}} | failure()
  def window(scope, limit_key, algorithm, p) do
    call(scope, "relay_fn.rl_window", [
      limit_key,
      Atom.to_string(algorithm),
      p.limit,
      p.window_ms,
      p.offset_ms,
      p.cost
    ])
    |> one(fn row ->
      {Repo.code!(row["result"], [:allowed, :limited]), row["count_after"], row["retry_after_ms"]}
    end)
  end

  # T-27
  @doc "Adds to or reads a sliding counter through `relay_fn.rl_counter`; returns the estimate."
  @spec counter(Relay.Scope.t(), String.t(), pos_integer(), :incr | :read, non_neg_integer()) ::
          {:ok, non_neg_integer()} | failure()
  def counter(scope, limit_key, window_ms, op, by) do
    scope
    |> call("relay_fn.rl_counter", [limit_key, window_ms, Atom.to_string(op), by])
    |> one(& &1["estimate"])
  end

  # TN-43
  @doc "Adds to a minute bucket ring through `relay_fn.rl_ring`; returns `{current_sum, baseline_sum}`."
  @spec ring(Relay.Scope.t(), String.t(), non_neg_integer(), pos_integer(), non_neg_integer()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | failure()
  def ring(scope, limit_key, cost, current, baseline) do
    scope
    |> call("relay_fn.rl_ring", [limit_key, cost, current, baseline])
    |> one(&{&1["current_sum"], &1["baseline_sum"]})
  end

  defp call(scope, function, params) do
    case Repo.in_scope(scope, fn _status -> Repo.call!(function, params) end) do
      {:ok, rows} -> {:ok, rows}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _other} -> unavailable()
    end
  rescue
    error in DBConnection.ConnectionError ->
      unavailable(error.__struct__)

    error in Postgrex.Error ->
      if match?(%{code: :raise_exception}, error.postgres),
        do: reraise(error, __STACKTRACE__),
        else: unavailable(error.__struct__)
  end

  defp one({:ok, [row]}, fun), do: {:ok, fun.(row)}
  defp one({:ok, _rows}, _fun), do: unavailable()
  defp one({:error, _} = error, _fun), do: error

  defp unavailable(reason \\ :unknown),
    do:
      {:error,
       Relay.Error.new(:limiter_unavailable, "limiter fallback failed", %{reason: reason})}
end
