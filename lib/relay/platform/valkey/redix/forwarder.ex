defmodule Relay.Platform.Valkey.Redix.Forwarder do
  @moduledoc """
  Holds the node's Redix pub/sub subscriptions and forwards their events to the processes registered for each channel, in the message format of `Relay.Platform.Valkey`. On start it marks every registered subscriber down and subscribes again, so a restart never leaves a subscriber believing it is connected.
  """

  use GenServer

  require Logger

  defstruct [:pubsub, :registry, channels: %{}]

  @type status :: :pending | :up

  @doc "Starts the forwarder."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Makes sure the channel is subscribed; tells `pid` at once if it already is."
  @spec ensure(GenServer.server(), String.t(), pid()) :: :ok
  def ensure(server, channel, pid), do: GenServer.call(server, {:ensure, channel, pid})

  @doc "Drops the channel's subscription when no process listens on it any more."
  @spec release(GenServer.server(), String.t()) :: :ok
  def release(server, channel), do: GenServer.call(server, {:release, channel})

  # T-45
  @impl GenServer
  def init(opts) do
    Process.flag(:message_queue_data, :off_heap)

    state = %__MODULE__{
      pubsub: Keyword.fetch!(opts, :pubsub),
      registry: Keyword.fetch!(opts, :registry)
    }

    registered = Registry.select(state.registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

    registered |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.each(&send(&1, {:valkey, :down}))

    channels =
      registered
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Map.new(fn channel -> {channel, subscribe(state, channel)} end)

    {:ok, %{state | channels: channels}}
  end

  @impl GenServer
  def handle_call({:ensure, channel, pid}, _from, state) do
    case Map.fetch(state.channels, channel) do
      {:ok, :up} ->
        send(pid, {:valkey, :up, channel})
        {:reply, :ok, state}

      {:ok, :pending} ->
        {:reply, :ok, state}

      :error ->
        {:reply, :ok, put_in(state.channels[channel], subscribe(state, channel))}
    end
  end

  def handle_call({:release, channel}, _from, state),
    do: {:reply, :ok, maybe_drop(state, channel)}

  @impl GenServer
  def handle_info({:redix_pubsub, _pid, _ref, :subscribed, %{channel: channel}}, state) do
    if Map.has_key?(state.channels, channel) do
      dispatch(state, channel, {:valkey, :up, channel})
      {:noreply, put_in(state.channels[channel], :up)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:redix_pubsub, _pid, _ref, :message, %{channel: channel, payload: payload}},
        state
      ) do
    case listeners(state, channel) do
      [] ->
        {:noreply, maybe_drop(state, channel)}

      pids ->
        Enum.each(pids, &send(&1, {:valkey, :message, channel, payload}))
        {:noreply, state}
    end
  end

  def handle_info({:redix_pubsub, _pid, _ref, :disconnected, _properties}, state) do
    up = for {channel, :up} <- state.channels, do: channel

    if up != [] do
      Logger.warning("valkey pub/sub connection lost", channels: length(up))

      up
      |> Enum.flat_map(&listeners(state, &1))
      |> Enum.uniq()
      |> Enum.each(&send(&1, {:valkey, :down}))
    end

    {:noreply, %{state | channels: Map.new(state.channels, fn {ch, _} -> {ch, :pending} end)}}
  end

  def handle_info({:redix_pubsub, _pid, _ref, _type, _properties}, state), do: {:noreply, state}

  defp subscribe(state, channel) do
    {:ok, _ref} = Redix.PubSub.subscribe(state.pubsub, channel, self())
    :pending
  end

  defp maybe_drop(state, channel) do
    if Map.has_key?(state.channels, channel) and listeners(state, channel) == [] do
      :ok = Redix.PubSub.unsubscribe(state.pubsub, channel, self())
      %{state | channels: Map.delete(state.channels, channel)}
    else
      state
    end
  end

  defp listeners(state, channel),
    do: state.registry |> Registry.lookup(channel) |> Enum.map(&elem(&1, 0))

  defp dispatch(state, channel, message),
    do: state |> listeners(channel) |> Enum.each(&send(&1, message))
end
