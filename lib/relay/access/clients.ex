defmodule Relay.Access.Clients do
  @moduledoc """
  The node cache of API client resolutions (S-72). An entry maps an Access tenant and client to the Relay trace it resolved to and the generation it was read at. Every write to `relay.api_clients` raises the installation's generation in the same transaction and signals `relay:s:signal:api_clients` after it commits; this process owns the table, raises the node's known generation on the signal, on a re-read tick (every second while Valkey is unavailable) and every 30 seconds in any case, and an entry older than the known generation is resolved again. A revocation or a suspension therefore reaches every node along the same path as a kill switch (API-44, TN-24 (5), TN-36).

  With `config :relay, Relay.Access, autoload: false` the process neither reads the generation nor subscribes by itself.
  """

  use GenServer

  require Logger

  alias Relay.Access.ClientStore

  @table __MODULE__
  @poll_ms 30_000

  @doc "Starts the process that owns the cache."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Signal topic of API client writes."
  @spec topic() :: String.t()
  def topic, do: Relay.Platform.system_signal_topic(["api_clients"])

  # TN-36
  @doc "The generation this node knows."
  @spec generation() :: non_neg_integer()
  def generation do
    case :ets.lookup(@table, :generation) do
      [{:generation, generation}] -> generation
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  # API-44
  # TN-36
  @doc "Raises the generation this node knows; entries read before it are resolved again."
  @spec advance(non_neg_integer()) :: :ok
  def advance(generation) when is_integer(generation) and generation >= 0,
    do: GenServer.call(__MODULE__, {:advance, generation})

  @doc "Forgets every cached resolution and the known generation of this node."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # API-71
  # TN-36
  @doc "Resolves an Access client of an Access tenant, from the cache while its entry is current."
  @spec resolve(String.t(), String.t()) :: {:ok, ClientStore.resolved()} | :unknown
  def resolve(access_tenant_id, access_client_id) do
    key = {access_tenant_id, access_client_id}
    known = generation()

    case lookup(key) do
      {:ok, %{generation: at} = resolved} when at >= known -> {:ok, resolved}
      _stale_or_missing -> read(key)
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, {:client, key}) do
      [{_key, resolved}] -> {:ok, resolved}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp read({access_tenant_id, access_client_id} = key) do
    case ClientStore.resolve(access_tenant_id, access_client_id) do
      [resolved] ->
        :ok = advance(resolved.generation)
        cache(key, resolved)
        {:ok, resolved}

      _none_or_ambiguous ->
        :unknown
    end
  end

  defp cache(key, resolved), do: GenServer.cast(__MODULE__, {:cache, key, resolved})

  @impl GenServer
  def init(opts) do
    _ = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    autoload = Keyword.get(opts, :autoload, Keyword.get(Relay.Access.config(), :autoload, true))

    if autoload do
      _ = Relay.Platform.subscribe_signal(topic())
      send(self(), :poll)
    end

    {:ok, %{autoload: autoload}}
  end

  @impl GenServer
  def handle_call({:advance, generation}, _from, state) do
    raise_generation(generation)
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:cache, key, resolved}, state) do
    :ets.insert(@table, {{:client, key}, resolved})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    poll()
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, state}
  end

  def handle_info({:relay_signal, _topic, {:seq, generation}}, state) do
    raise_generation(generation)
    {:noreply, state}
  end

  def handle_info({:relay_signal, _topic, :poll}, state) do
    poll()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp raise_generation(generation) when is_integer(generation) do
    if generation > generation(), do: :ets.insert(@table, {:generation, generation})
  end

  defp poll do
    raise_generation(ClientStore.generation())
  rescue
    exception ->
      Logger.warning("API client generation not read", error: Exception.message(exception))
  end
end
