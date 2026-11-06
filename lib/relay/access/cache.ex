defmodule Relay.Access.Cache do
  @moduledoc """
  The node's short-lived memory of Relay's own calls to Access and of the tenant realms (E-96, E-98, E-100): the realm issuers of a tenant, the keys of a realm, the tenant snapshot address, Relay's Access access token, the public key of its Access client key and the last `DPoP-Nonce` of an Access origin. Entries expire by the monotonic clock; nothing here is durable, and a node that lost the table asks Access again. The table is protected: every read is direct, every write goes through the owning process. While that process is not running every read misses and every write is dropped.
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
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms >= 0,
    do: write({:put, key, value, Relay.Clock.monotonic_ms() + ttl_ms}, :ok)

  @doc "Forgets `key`."
  @spec delete(term()) :: :ok
  def delete(key), do: write({:delete, key}, :ok)

  @doc "Forgets every entry whose key matches the ETS match pattern `pattern` (`:_` forgets everything)."
  @spec forget(term()) :: :ok
  def forget(pattern), do: write({:forget, pattern}, :ok)

  @doc "Claims the right to ask Access again for `key`: true at most once every `interval_ms` milliseconds per node."
  @spec claim(term(), pos_integer()) :: boolean()
  def claim(key, interval_ms) when is_integer(interval_ms) and interval_ms > 0,
    do: write({:claim, key, Relay.Clock.monotonic_ms(), interval_ms}, true)

  defp write(request, absent) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, _not_running -> absent
  end

  @impl GenServer
  def init(_opts) do
    _ = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, key, value, expires_ms}, _from, state) do
    true = :ets.insert(@table, {key, value, expires_ms})
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    true = :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  def handle_call({:forget, pattern}, _from, state) do
    true = :ets.match_delete(@table, {pattern, :_, :_})
    {:reply, :ok, state}
  end

  def handle_call({:claim, key, now, interval_ms}, _from, state) do
    case :ets.lookup(@table, {:claim, key}) do
      [{_key, true, expires_ms}] when expires_ms > now ->
        {:reply, false, state}

      _missing_or_expired ->
        true = :ets.insert(@table, {{:claim, key}, true, now + interval_ms})
        {:reply, true, state}
    end
  end
end
