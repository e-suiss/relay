defmodule Relay.Platform.Signal.Hub do
  @moduledoc """
  Node-local signal hub. It holds one Valkey subscription per topic for all local subscribers, forwards signals to them and, while a topic's subscription is not confirmed, sends them a re-read tick at the configured polling interval.
  """

  use GenServer

  alias Relay.Platform.Signal
  alias Relay.Platform.Valkey

  defstruct [:adapter, :poll_interval_ms, topics: %{}, monitors: %{}]

  @doc "Starts the hub."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Registers `pid` for a topic."
  @spec subscribe(GenServer.server(), Signal.topic(), pid()) :: :ok
  def subscribe(hub, topic, pid), do: GenServer.call(hub, {:subscribe, topic, pid})

  @doc "Removes `pid` from a topic."
  @spec unsubscribe(GenServer.server(), Signal.topic(), pid()) :: :ok
  def unsubscribe(hub, topic, pid), do: GenServer.call(hub, {:unsubscribe, topic, pid})

  @doc "Returns each topic with its subscription status."
  @spec topics(GenServer.server()) :: %{Signal.topic() => :pending | :up}
  def topics(hub), do: GenServer.call(hub, :topics)

  # T-45
  @impl GenServer
  def init(opts) do
    Process.flag(:message_queue_data, :off_heap)

    state = %__MODULE__{
      adapter: Keyword.get_lazy(opts, :adapter, &Valkey.adapter/0),
      poll_interval_ms: Keyword.get_lazy(opts, :poll_interval_ms, &configured_interval/0)
    }

    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:subscribe, topic, pid}, _from, state) do
    state =
      case Map.fetch(state.topics, topic) do
        {:ok, entry} ->
          if entry.status == :up, do: send(pid, {:relay_signal, topic, :poll})
          put_in(state.topics[topic].subscribers, MapSet.put(entry.subscribers, pid))

        :error ->
          _ = Valkey.subscribe(topic, state.adapter)
          put_in(state.topics[topic], %{status: :pending, subscribers: MapSet.new([pid])})
      end

    {:reply, :ok, monitor(state, pid)}
  end

  def handle_call({:unsubscribe, topic, pid}, _from, state),
    do: {:reply, :ok, drop(state, topic, pid)}

  def handle_call(:topics, _from, state),
    do: {:reply, Map.new(state.topics, fn {topic, entry} -> {topic, entry.status} end), state}

  @impl GenServer
  def handle_info({:valkey, :message, topic, payload}, state) do
    notify(state, topic, Signal.decode(payload))
    {:noreply, state}
  end

  # T-9 (2)
  def handle_info({:valkey, :up, topic}, state) do
    case Map.fetch(state.topics, topic) do
      {:ok, _entry} ->
        notify(state, topic, :poll)
        {:noreply, put_in(state.topics[topic].status, :up)}

      :error ->
        {:noreply, state}
    end
  end

  # T-9 (3)
  def handle_info({:valkey, :down}, state) do
    topics = Map.new(state.topics, fn {topic, entry} -> {topic, %{entry | status: :pending}} end)
    {:noreply, %{state | topics: topics}}
  end

  def handle_info(:poll, state) do
    for {topic, %{status: :pending}} <- state.topics, do: notify(state, topic, :poll)
    schedule(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | monitors: Map.delete(state.monitors, pid)}

    state =
      Enum.reduce(Map.keys(state.topics), state, fn topic, acc -> drop(acc, topic, pid) end)

    {:noreply, state}
  end

  defp notify(state, topic, event) do
    case Map.fetch(state.topics, topic) do
      {:ok, entry} -> Enum.each(entry.subscribers, &send(&1, {:relay_signal, topic, event}))
      :error -> :ok
    end
  end

  defp monitor(state, pid) do
    if Map.has_key?(state.monitors, pid),
      do: state,
      else: put_in(state.monitors[pid], Process.monitor(pid))
  end

  defp drop(state, topic, pid) do
    case Map.fetch(state.topics, topic) do
      {:ok, entry} ->
        subscribers = MapSet.delete(entry.subscribers, pid)

        if MapSet.size(subscribers) == 0 do
          :ok = Valkey.unsubscribe(topic, state.adapter)
          %{state | topics: Map.delete(state.topics, topic)}
        else
          put_in(state.topics[topic].subscribers, subscribers)
        end

      :error ->
        state
    end
  end

  defp schedule(state), do: Process.send_after(self(), :poll, state.poll_interval_ms)

  defp configured_interval,
    do:
      :relay
      |> Application.fetch_env!(Relay.Platform.Signal)
      |> Keyword.fetch!(:poll_interval_ms)
end
