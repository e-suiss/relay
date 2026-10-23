defmodule Relay.Datasets.Cache do
  @moduledoc """
  Node-local cache of active data set versions, held in a private ETS table of the cache process (T-46). A miss subscribes the cache to the entry's signal topic before the caller reads PostgreSQL, so a signal that arrives during the read discards the stale result instead of caching it. Any signal or re-read tick on a topic drops its entries, so while Valkey is unavailable every read goes to PostgreSQL (T-9).
  """

  use GenServer

  @type key :: term()
  @type option :: {:name, atom()} | {:subscribe, (String.t() -> term())}

  @doc "Starts the cache; `:subscribe` subscribes the cache process to a signal topic."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # OP-65 (6)
  @doc """
  Returns the cached value of `key`, or calls `load` in the caller and caches its `{:ok, value}` result unless a signal for `topic` arrived meanwhile. With `cache: false` the result of `load` is returned without being cached.
  """
  @spec fetch(
          GenServer.server(),
          key(),
          String.t(),
          (-> {:ok, term()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, term()} | {:error, term()}
  def fetch(cache, key, topic, load, opts \\ []) when is_function(load, 0) do
    if Keyword.get(opts, :cache, true) do
      case GenServer.call(cache, {:lookup, key, topic}) do
        {:hit, value} -> {:ok, value}
        {:miss, generation} -> load_and_put(cache, key, generation, load)
      end
    else
      load.()
    end
  end

  defp load_and_put(cache, key, generation, load) do
    with {:ok, value} <- load.() do
      :ok = GenServer.call(cache, {:put, key, generation, value})
      {:ok, value}
    end
  end

  @doc "Drops the entry of `key`."
  @spec invalidate(GenServer.server(), key()) :: :ok
  def invalidate(cache, key), do: GenServer.call(cache, {:invalidate, key})

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       table: :ets.new(__MODULE__, [:set, :private]),
       subscribe: Keyword.get(opts, :subscribe, &Relay.Platform.subscribe_signal/1),
       topics: %{},
       generations: %{}
     }}
  end

  @impl GenServer
  def handle_call({:lookup, key, topic}, _from, state) do
    case :ets.lookup(state.table, key) do
      [{^key, value}] -> {:reply, {:hit, value}, state}
      [] -> {:reply, {:miss, Map.get(state.generations, key, 0)}, watch(state, key, topic)}
    end
  end

  def handle_call({:put, key, generation, value}, _from, state) do
    if Map.get(state.generations, key, 0) == generation,
      do: :ets.insert(state.table, {key, value})

    {:reply, :ok, state}
  end

  def handle_call({:invalidate, key}, _from, state), do: {:reply, :ok, drop(state, key)}

  @impl GenServer
  def handle_info({:relay_signal, topic, _event}, state) do
    keys = Map.get(state.topics, topic, MapSet.new())
    {:noreply, Enum.reduce(keys, state, &drop(&2, &1))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp watch(state, key, topic) do
    case state.topics do
      %{^topic => keys} ->
        put_in(state.topics[topic], MapSet.put(keys, key))

      %{} ->
        _ = state.subscribe.(topic)
        put_in(state.topics[topic], MapSet.new([key]))
    end
  end

  defp drop(state, key) do
    :ets.delete(state.table, key)
    update_in(state.generations, &Map.update(&1, key, 1, fn n -> n + 1 end))
  end
end
