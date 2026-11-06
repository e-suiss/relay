defmodule Relay.Access.Cache do
  @moduledoc """
  The node's short-lived memory of Relay's own calls to Access (E-98): Relay's Access access token, the public key of its DPoP key and the last `DPoP-Nonce` of an Access origin. Entries expire by the monotonic clock; nothing here is durable, and a node that lost the table asks Access again. While the owning process is not running every read misses and every write is dropped.
  """

  use GenServer

  @table __MODULE__

  @doc "Starts the process that owns the table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The value under `key` while it has not expired."
  @spec fetch(term()) :: {:ok, term()} | :miss
  def fetch(key) do
    now = Relay.Clock.monotonic_ms()

    case :ets.lookup(@table, key) do
      [{^key, value, expires_ms}] when expires_ms > now -> {:ok, value}
      _missing_or_expired -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Keeps `value` under `key` for `ttl_ms` milliseconds."
  @spec put(term(), term(), non_neg_integer()) :: :ok
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms >= 0 do
    true = :ets.insert(@table, {key, value, Relay.Clock.monotonic_ms() + ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets `key`."
  @spec delete(term()) :: :ok
  def delete(key) do
    true = :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Claims the right to ask Access again for `key`: true at most once every `interval_ms` milliseconds per node."
  @spec claim(term(), pos_integer()) :: boolean()
  def claim(key, interval_ms) do
    case fetch({:claim, key}) do
      {:ok, _claimed} ->
        false

      :miss ->
        :ok = put({:claim, key}, true, interval_ms)
        true
    end
  end

  @impl GenServer
  def init(_opts) do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
