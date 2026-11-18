defmodule Relay.FaultInjection.Cache do
  @moduledoc """
  The node's fault injection records (OP-92), read the way the kill switch cache reads its state (TN-39): PostgreSQL is the truth, a write signals `relay:s:signal:faultinjection` after it commits, and the cache process reads the records in force when a signal or a re-read tick arrives and every 30 seconds in any case. The records are published as one immutable list in `:persistent_term`, so the delivery path pays one constant-time lookup and, while no record is in force, nothing more.

  Before the first read and after a failed one nothing is injected from a record the node does not hold; expiry is applied at evaluation time, so a record whose TTL passes stops acting without a reload.

  Telemetry: `[:relay, :fault_injection, :active]` (`count`) per target environment with the node's chaos mode, after every read.
  """

  use GenServer

  require Logger

  alias Relay.FaultInjection.Record
  alias Relay.FaultInjection.Store

  @refresh_ms 30_000

  @type name :: atom() | reference()

  @doc "Starts the cache process; a `:name` that is not an atom keys the state without registering the process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    registration = if is_atom(name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), registration)
  end

  @doc "Signal topic of fault injection writes."
  @spec topic() :: String.t()
  def topic, do: Relay.Platform.system_signal_topic(["faultinjection"])

  # OP-92
  @doc "The records the cache `name` holds; an empty list before the first read."
  @spec current(name()) :: [Record.t()]
  def current(name \\ __MODULE__), do: :persistent_term.get({__MODULE__, name}, [])

  @doc "Publishes `records` as the state of the cache `name`; the `:persistent_term` write happens only on a change."
  @spec put(name(), [Record.t()]) :: [Record.t()]
  def put(name \\ __MODULE__, records) when is_list(records) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      ^records -> records
      _ -> :persistent_term.put({__MODULE__, name}, records)
    end

    records
  end

  @doc "Forgets the state of the cache `name`."
  @spec forget(name()) :: :ok
  def forget(name \\ __MODULE__) do
    _ = :persistent_term.erase({__MODULE__, name})
    :ok
  end

  @doc "Re-reads the records now."
  @spec reload(GenServer.server()) :: {:ok, [Record.t()]} | {:error, term()}
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload, 30_000)

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    topic = Keyword.get_lazy(opts, :topic, &topic/0)
    subscribe = Keyword.get(opts, :subscribe, &Relay.Platform.subscribe_signal/1)
    _ = subscribe.(topic)

    state = %{
      name: name,
      topic: topic,
      load: Keyword.get(opts, :load, fn -> Store.list(false, 1_000) end),
      chaos?: Keyword.get_lazy(opts, :chaos?, &Relay.FaultInjection.chaos_mode?/0),
      refresh_ms: Keyword.get(opts, :refresh_ms, @refresh_ms)
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:reload, _from, state), do: {:reply, load(state), state}

  @impl GenServer
  def handle_info(:refresh, state) do
    _ = load(state)
    Process.send_after(self(), :refresh, state.refresh_ms)
    {:noreply, state}
  end

  def handle_info({:relay_signal, topic, _signal}, %{topic: topic} = state) do
    _ = load(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp load(state) do
    case state.load.() do
      {:ok, records} ->
        records = put(state.name, records)
        report(records, state.chaos?)
        {:ok, records}

      {:error, error} ->
        Logger.warning("fault injection records not read; the last known records stay",
          error: inspect(error)
        )

        {:error, error}
    end
  rescue
    exception ->
      Logger.warning("fault injection records not read; the last known records stay",
        error: Exception.message(exception)
      )

      {:error, exception}
  end

  # OP-92
  defp report(records, chaos?) do
    now = Relay.Clock.utc_now()

    for environment <- [:live, :test] do
      count =
        Enum.count(records, &(&1.target_environment == environment and Record.in_force?(&1, now)))

      :telemetry.execute([:relay, :fault_injection, :active], %{count: count}, %{
        target_environment: environment,
        chaos_mode: chaos?
      })
    end

    :ok
  end
end
