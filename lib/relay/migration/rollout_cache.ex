defmodule Relay.Migration.RolloutCache do
  @moduledoc """
  The node's cache of staged rollout configurations (OP-53, OP-95). PostgreSQL is the truth; a write signals `relay:s:signal:rollout` after it commits and this process, which owns the table, forgets every entry when the signal arrives, on a re-read tick (every second while Valkey is unavailable) and on the write's own node at once. An entry is also read again once it is older than 30 seconds, so a change reaches every node within 60 seconds even without a signal. Without the process the configuration is read from the database every time.
  """

  use GenServer

  @table __MODULE__
  @max_age_ms 30_000

  @doc "Starts the process that owns the cache."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Signal topic of rollout configuration writes."
  @spec topic() :: String.t()
  def topic, do: Relay.Platform.system_signal_topic(["rollout"])

  # OP-53
  @doc "The cached configuration of a tenant environment while it is younger than 30 seconds, else `:miss`."
  @spec lookup(Relay.Scope.t()) :: {:ok, term()} | :miss
  def lookup(%Relay.Scope{tenant_id: tenant_id, environment: environment}) do
    now = Relay.Clock.monotonic_ms()

    case :ets.lookup(@table, {tenant_id, environment}) do
      [{_key, config, at}] when now - at < @max_age_ms -> {:ok, config}
      _missing_or_old -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Keeps a configuration read from the database."
  @spec put(Relay.Scope.t(), term()) :: :ok
  def put(%Relay.Scope{tenant_id: tenant_id, environment: environment}, config) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(
        __MODULE__,
        {:put, {tenant_id, environment}, config, Relay.Clock.monotonic_ms()}
      )
    end

    :ok
  end

  # OP-53
  @doc "Forgets every entry of this node."
  @spec forget() :: :ok
  def forget do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :forget)
    :ok
  end

  @impl GenServer
  def init(_opts) do
    _ = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    _ = Relay.Platform.subscribe_signal(topic())
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:forget, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:put, key, config, at}, state) do
    :ets.insert(@table, {key, config, at})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:relay_signal, _topic, _event}, state) do
    :ets.delete_all_objects(@table)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
