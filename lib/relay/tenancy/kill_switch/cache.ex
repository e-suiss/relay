defmodule Relay.Tenancy.KillSwitch.Cache do
  @moduledoc """
  The node's kill switch state (TN-38, TN-39). PostgreSQL is the truth; a write signals `relay:s:signal:killswitch` with its generation after it commits. The cache process reads the full set through `relay_ops.kill_switch_snapshot()` when a signal or a re-read tick arrives (the signal hub ticks every second while Valkey is unavailable) and every 30 seconds in any case (S-52), drops a result of a smaller generation than the one it holds, and publishes the set as one immutable value in `:persistent_term`, so a read is a constant-time lookup inside the node.

  A failed read keeps the last known snapshot and reports its age; expiry is still applied at evaluation time, so a record whose TTL passes during an outage stops applying. Before the first successful read the state is `:unknown` and nothing is sent. An outage never releases a record, and no copy is kept on disk: at start the node holds no state (INV-43).

  Telemetry: `[:relay, :kill_switch, :cache, :loaded]` (`generation`, `count`) and `[:relay, :kill_switch, :cache, :stale]` (`age_ms`, `code`).
  """

  use GenServer

  require Logger

  alias Relay.Tenancy.KillSwitch.Snapshot
  alias Relay.Tenancy.KillSwitch.Store

  @refresh_ms 30_000

  @type name :: atom() | reference()
  @type option ::
          {:name, name()}
          | {:subscribe, (String.t() -> term())}
          | {:topic, String.t()}
          | {:load, (-> {:ok, non_neg_integer(), list()} | {:error, Relay.Error.t()})}
          | {:refresh_ms, pos_integer()}

  @doc "Starts the cache process; a `:name` that is not an atom keys the state without registering the process."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    registration = if is_atom(name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), registration)
  end

  @doc "Signal topic of kill switch writes."
  @spec topic() :: String.t()
  def topic, do: Relay.Platform.system_signal_topic(["killswitch"])

  # TN-38
  # INV-43
  @doc "Returns the current snapshot of the cache `name`, or `:unknown` before its first successful read."
  @spec current(name()) :: Snapshot.t() | :unknown
  def current(name \\ __MODULE__), do: :persistent_term.get({__MODULE__, name}, :unknown)

  @doc "Publishes `snapshot` as the current state of the cache `name` when its generation is not older than the current one and it differs from the held one, so the `:persistent_term` write happens only on a change (T-45 (5)); returns the snapshot in force."
  @spec put(name(), Snapshot.t()) :: Snapshot.t()
  def put(name \\ __MODULE__, %Snapshot{} = snapshot) do
    case current(name) do
      %Snapshot{generation: generation} = held when generation > snapshot.generation ->
        held

      ^snapshot ->
        snapshot

      _ ->
        :persistent_term.put({__MODULE__, name}, snapshot)
        snapshot
    end
  end

  @doc "Forgets the state of the cache `name`; the next read is `:unknown`."
  @spec forget(name()) :: :ok
  def forget(name \\ __MODULE__) do
    _ = :persistent_term.erase({__MODULE__, name})
    :ok
  end

  @doc "Re-reads the state now and returns the snapshot in force or the read error."
  @spec reload(GenServer.server()) :: {:ok, Snapshot.t()} | {:error, Relay.Error.t()}
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
      load: Keyword.get(opts, :load, &Store.snapshot/0),
      refresh_ms: Keyword.get(opts, :refresh_ms, @refresh_ms),
      loaded_at_ms: nil
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    {result, state} = load(state)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    {_result, state} = load(state)
    Process.send_after(self(), :refresh, state.refresh_ms)
    {:noreply, state}
  end

  def handle_info({:relay_signal, topic, {:seq, generation}}, %{topic: topic} = state) do
    case current(state.name) do
      %Snapshot{generation: held} when held >= generation -> {:noreply, state}
      _ -> {:noreply, state |> load() |> elem(1)}
    end
  end

  def handle_info({:relay_signal, topic, :poll}, %{topic: topic} = state),
    do: {:noreply, state |> load() |> elem(1)}

  def handle_info(_message, state), do: {:noreply, state}

  defp load(state) do
    case state.load.() do
      {:ok, generation, records} ->
        snapshot = put(state.name, Snapshot.new(generation, records))

        :telemetry.execute(
          [:relay, :kill_switch, :cache, :loaded],
          %{generation: snapshot.generation, count: snapshot.count},
          %{cache: state.name}
        )

        {{:ok, snapshot}, %{state | loaded_at_ms: Relay.Clock.monotonic_ms()}}

      {:error, %Relay.Error{} = error} ->
        age = if state.loaded_at_ms, do: Relay.Clock.monotonic_ms() - state.loaded_at_ms

        :telemetry.execute([:relay, :kill_switch, :cache, :stale], %{age_ms: age}, %{
          cache: state.name,
          code: error.code
        })

        Logger.warning("kill switch state not read; the last known state stays",
          code: error.code
        )

        {{:error, error}, state}
    end
  rescue
    exception ->
      load_failed(state, exception)
  end

  defp load_failed(state, exception) do
    error =
      Relay.Error.new(:kill_switch_unreadable, "kill switch state could not be read", %{
        error: Exception.message(exception)
      })

    age = if state.loaded_at_ms, do: Relay.Clock.monotonic_ms() - state.loaded_at_ms

    :telemetry.execute([:relay, :kill_switch, :cache, :stale], %{age_ms: age}, %{
      cache: state.name,
      code: error.code
    })

    {{:error, error}, state}
  end
end
