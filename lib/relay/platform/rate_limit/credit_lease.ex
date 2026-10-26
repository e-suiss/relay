defmodule Relay.Platform.RateLimit.CreditLease do
  @moduledoc """
  Node-local credit blocks for burst-friendly channels (T-20 (5)). A node holds at most one block per tenant, environment, limit key and lane: the block is taken from the central GCRA with `cost = block_size`, then spent locally through an `:atomics` counter until it is used up or its validity (`lease time + block_size * T`) ends. Unspent credit is dropped, never returned, so the cluster-wide overrun stays at most `(N - 1) * k`. A channel with a strict per-second limit (SMS) never leases; when no block can be taken the decision is made centrally one request at a time.

  The default of T-91 (1) leases on `push`, `web_push` and `email` with `k = max(1, floor(B / 10))`; the channel parameters can only narrow it.

  The blocks live in one named ETS table for the whole node, owned by this server, never in a table per tenant (T-45 (5)); expired blocks are swept every minute. Validity is measured with the node's monotonic clock, as a duration.
  """

  use GenServer

  @table __MODULE__
  @sweep_ms 60_000
  @lease_channels ~w(push web_push email)

  @type key :: term()
  @type lease :: {boolean(), pos_integer() | nil}

  # T-20 (5)
  # T-91 (1)
  @doc "The default lease of a channel for a GCRA limit with burst `burst`: `{true, max(1, floor(B / 10))}` on push, web push and email, `{false, nil}` elsewhere."
  @spec default(String.t(), pos_integer()) :: lease()
  def default(channel, burst) when channel in @lease_channels and is_integer(burst) and burst > 0,
    do: {true, max(1, div(burst, 10))}

  def default(_channel, _burst), do: {false, nil}

  # T-20 (5)
  @doc "The block size to lease, or nil when this limit does not lease: the channel must allow leasing and the burst must hold a whole block."
  @spec block_size(lease(), pos_integer()) :: pos_integer() | nil
  def block_size({true, nil}, burst), do: block_size({true, max(1, div(burst, 10))}, burst)

  def block_size({true, size}, burst) when is_integer(size) and size > 0 and burst >= size,
    do: size

  def block_size(_lease, _burst), do: nil

  # T-20 (5)
  @doc """
  Spends `cost` from the node's block for `key`. Without a usable block it calls `lease_fun.()`, which returns `{:allow, valid_ms}` when the central limiter granted a block of `block_size` or `:deny`; a granted block is stored with `block_size - cost` left. Returns `:allowed` when the cost was covered by a block and `:central` when the caller must decide this request centrally.
  """
  @spec spend(
          key(),
          pos_integer(),
          pos_integer(),
          (-> {:allow, pos_integer()} | :deny),
          keyword()
        ) ::
          :allowed | :central
  def spend(key, cost, block_size, lease_fun, opts \\ [])
      when is_integer(cost) and cost > 0 and is_integer(block_size) and block_size > 0 do
    table = Keyword.get(opts, :table, @table)
    clock = Keyword.get(opts, :clock, Relay.Clock)
    now = clock.monotonic_ms()

    cond do
      cost > block_size -> :central
      :ets.info(table, :type) == :undefined -> :central
      take(table, key, cost, now) -> :allowed
      true -> lease(table, key, cost, block_size, lease_fun, now)
    end
  end

  defp take(table, key, cost, now) do
    case :ets.lookup(table, key) do
      [{^key, ref, expires}] when expires > now -> :atomics.sub_get(ref, 1, cost) >= 0
      _ -> false
    end
  end

  defp lease(table, key, cost, block_size, lease_fun, now) do
    case lease_fun.() do
      {:allow, valid_ms} ->
        ref = :atomics.new(1, signed: true)
        :atomics.put(ref, 1, block_size - cost)
        :ets.insert(table, {key, ref, now + valid_ms})
        :allowed

      :deny ->
        :central
    end
  end

  @doc "Starts the owner of the node's block table. Options: `:clock`."
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
    now = state.clock.monotonic_ms()
    :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
