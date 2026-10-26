defmodule Relay.Platform.Concurrency.Store do
  @moduledoc """
  The PostgreSQL fallback of the cluster-wide concurrency limits: `relay_fn.cc_acquire` and `relay_fn.cc_release` over `relay_queue.concurrency_slots`, each in its own short scoped transaction. Slots are reused, never deleted; a crashed holder's slot frees itself when its lease ends. Lease time is the database's `clock_timestamp()`.
  """

  alias Relay.Repo

  # T-22
  @doc "Takes or renews a slot; returns `{:granted | :renewed | :full, in_use, wait_ms}`."
  @spec acquire(Relay.Scope.t(), String.t(), pos_integer(), String.t(), pos_integer()) ::
          {:ok, {:granted | :renewed | :full, non_neg_integer(), non_neg_integer()}}
          | {:error, Relay.Error.t()}
  def acquire(scope, counter_key, limit, holder, lease_ms) do
    call(scope, fn ->
      [row] = Repo.call!("relay_fn.cc_acquire", [counter_key, limit, holder, lease_ms])

      {Repo.code!(row["result"], [:granted, :renewed, :full]), row["in_use"], row["wait_ms"]}
    end)
  end

  # T-22
  @doc "Frees every slot `holder` holds on the counter."
  @spec release(Relay.Scope.t(), String.t(), String.t()) ::
          {:ok, :released | :not_held} | {:error, Relay.Error.t()}
  def release(scope, counter_key, holder) do
    call(scope, fn ->
      [row] = Repo.call!("relay_fn.cc_release", [counter_key, holder])
      Repo.code!(row["cc_release"], [:released, :not_held])
    end)
  end

  defp call(scope, fun) do
    case Repo.in_scope(scope, fn _status -> fun.() end) do
      {:ok, result} -> {:ok, result}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _other} -> unavailable(:unknown)
    end
  rescue
    error in DBConnection.ConnectionError ->
      unavailable(error.__struct__)

    error in Postgrex.Error ->
      if match?(%{code: :raise_exception}, error.postgres),
        do: reraise(error, __STACKTRACE__),
        else: unavailable(error.__struct__)
  end

  defp unavailable(reason),
    do:
      {:error,
       Relay.Error.new(:limiter_unavailable, "concurrency fallback failed", %{reason: reason})}
end
