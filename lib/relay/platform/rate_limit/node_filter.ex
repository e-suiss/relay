defmodule Relay.Platform.RateLimit.NodeFilter do
  @moduledoc """
  The node-local first pass of the API rate limit (T-42, T-94): a cheap filter in front of the cluster limiter, never a replacement for it. It runs Relay's own GCRA arithmetic (the emission interval and theoretical arrival time of `Relay.Platform.RateLimit.Gcra`, T-19) on the node's monotonic clock (`Relay.Clock.monotonic_ms/0`) over one ETS table for the whole node; the node's wall clock never enters it (INV-50, T-11) and there is no Hammer.

  The filter only counts what the cluster limiter allowed (`note/5`), with the same limit and key. A node's allowed consumption is part of the cluster's, so the node-local theoretical arrival time is never later than the cluster one: when `check/5` refuses, the cluster limiter would refuse as well, and the request is answered without asking it. Everything else is decided by the cluster limiter. Only GCRA limits are filtered.

  The table is public and written with compare-and-swap, so concurrent callers never lose a note; an entry whose arrival time has passed is the same as no entry and is swept every minute. It is one table keyed by tenant, environment and limit key, never a table per tenant (T-45 (5)).
  """

  use GenServer

  alias Relay.Platform.RateLimit.Gcra
  alias Relay.Platform.RateLimit.Limit

  @table __MODULE__
  @sweep_ms 60_000

  @type option :: {:clock, module()} | {:table, atom() | :ets.tid()}

  # T-94
  # T-42
  @doc "Checks `cost` on `limit` for the key of `key_parts` in `scope` against this node's own consumption: `:pass` hands the request to the cluster limiter, `{:deny, retry_ms}` refuses it here. Options: `:clock` and `:table`."
  @spec check(Relay.Scope.t(), Limit.t(), [String.t()], pos_integer(), [option()]) ::
          :pass | {:deny, pos_integer()}
  def check(scope, limit, key_parts, cost, opts \\ [])

  def check(%Relay.Scope{} = scope, %Limit{algorithm: :gcra} = limit, key_parts, cost, opts)
      when is_integer(cost) and cost > 0 do
    table = Keyword.get(opts, :table, @table)

    with {:ok, key} <- key(scope, limit, key_parts),
         true <- present?(table),
         {:ok, tat} <- lookup(table, key) do
      decide(limit, tat, cost, now_us(opts))
    else
      _ -> :pass
    end
  end

  def check(%Relay.Scope{}, %Limit{}, _key_parts, _cost, _opts), do: :pass

  defp decide(limit, tat, cost, now) do
    emission = Gcra.emission_us(limit.limit, limit.period_ms)
    allowance = limit.burst * emission
    ahead = max(tat, now) + cost * emission - now

    if cost <= limit.burst and ahead > allowance,
      do: {:deny, max(Gcra.ceil_div(ahead - allowance, 1000), 1)},
      else: :pass
  end

  # T-94
  @doc "Notes `cost` that the cluster limiter allowed on `limit` for the key of `key_parts` in `scope`. Options: `:clock` and `:table`."
  @spec note(Relay.Scope.t(), Limit.t(), [String.t()], pos_integer(), [option()]) :: :ok
  def note(scope, limit, key_parts, cost, opts \\ [])

  def note(%Relay.Scope{} = scope, %Limit{algorithm: :gcra} = limit, key_parts, cost, opts)
      when is_integer(cost) and cost > 0 do
    table = Keyword.get(opts, :table, @table)

    with {:ok, key} <- key(scope, limit, key_parts),
         true <- present?(table) do
      advance(table, key, Gcra.emission_us(limit.limit, limit.period_ms) * cost, now_us(opts))
    end

    :ok
  end

  def note(%Relay.Scope{}, %Limit{}, _key_parts, _cost, _opts), do: :ok

  defp advance(table, key, step_us, now) do
    case :ets.lookup(table, key) do
      [] ->
        if :ets.insert_new(table, {key, now + step_us}),
          do: :ok,
          else: advance(table, key, step_us, now)

      [{^key, tat}] ->
        spec = [{{key, tat}, [], [{{{:const, key}, max(tat, now) + step_us}}]}]

        if :ets.select_replace(table, spec) == 1,
          do: :ok,
          else: advance(table, key, step_us, now)
    end
  end

  defp key(scope, limit, key_parts) do
    case Limit.key(limit, key_parts) do
      {:ok, limit_key} -> {:ok, {scope.tenant_id, scope.environment, limit_key}}
      {:error, _error} -> :error
    end
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, tat}] -> {:ok, tat}
      [] -> :none
    end
  end

  defp present?(table), do: :ets.info(table, :type) != :undefined

  defp now_us(opts), do: Keyword.get(opts, :clock, Relay.Clock).monotonic_ms() * 1000

  @doc "Starts the owner of the node's filter table. Options: `:clock`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule()
    {:ok, %{table: table, clock: Keyword.get(opts, :clock, Relay.Clock)}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep(state.table, state.clock.monotonic_ms() * 1000)
    schedule()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "Drops the entries of `table` whose arrival time is not after `now_us`; such an entry decides like no entry."
  @spec sweep(atom() | :ets.tid(), integer()) :: non_neg_integer()
  def sweep(table, now_us),
    do: :ets.select_delete(table, [{{:_, :"$1"}, [{:"=<", :"$1", now_us}], [true]}])

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
