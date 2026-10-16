defmodule Relay.Platform.Queue.Notifier do
  @moduledoc """
  Relay's job queue notifier: an `Oban.Notifier` over Valkey pub/sub. Each Oban channel maps to one system channel scoped by the queue prefix. When Valkey is unavailable, publishing fails fast and receives stop, so Oban's connectivity check reports the node isolated and the queue falls back to polling the database; a lost notification costs latency, never a job.
  """

  @behaviour Oban.Notifier

  use GenServer

  alias Oban.Notifier.Registry, as: Listeners
  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Key

  require Logger

  defstruct [:conf, :adapter, channels: %{}, connected?: false]

  # T-55
  @impl Oban.Notifier
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Oban.Notifier
  def listen(server, channels), do: GenServer.call(server, {:listen, channels})

  @impl Oban.Notifier
  def unlisten(server, channels), do: GenServer.call(server, {:unlisten, channels})

  # T-10
  @impl Oban.Notifier
  def notify(server, channel, payload), do: GenServer.call(server, {:notify, channel, payload})

  @doc "Returns the Valkey channel that carries an Oban channel for a queue prefix."
  @spec channel_name(String.t(), atom()) :: String.t()
  def channel_name(prefix, channel) when is_binary(prefix) and is_atom(channel),
    do: Key.system_channel(["oban", prefix, Atom.to_string(channel)])

  @impl GenServer
  def init(opts) do
    conf = Keyword.fetch!(opts, :conf)
    adapter = Keyword.get_lazy(opts, :adapter, &Valkey.adapter/0)
    state = %__MODULE__{conf: conf, adapter: adapter}
    {:ok, state, {:continue, :listen}}
  end

  @impl GenServer
  def handle_continue(:listen, state),
    do: {:noreply, add_channels(state, Listeners.channels(state.conf))}

  @impl GenServer
  def handle_call({:listen, channels}, _from, state),
    do: {:reply, :ok, add_channels(state, channels)}

  def handle_call({:unlisten, channels}, _from, state) do
    idle = Enum.filter(channels, &(Listeners.listeners(state.conf, &1) == []))

    remaining =
      Enum.reduce(idle, state.channels, fn channel, acc ->
        name = channel_name(state.conf.prefix, channel)

        if Map.has_key?(acc, name) do
          :ok = Valkey.unsubscribe(name, state.adapter)
          Map.delete(acc, name)
        else
          acc
        end
      end)

    {:reply, :ok, %{state | channels: remaining}}
  end

  def handle_call({:notify, channel, payload}, _from, state) do
    name = channel_name(state.conf.prefix, channel)

    reply =
      case Valkey.publish_many(name, payload, state.adapter) do
        :ok -> :ok
        {:error, error} -> {:error, RuntimeError.exception(error.message)}
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info({:valkey, :message, name, payload}, state) do
    case Map.fetch(state.channels, name) do
      {:ok, channel} -> relay(state, channel, payload)
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:valkey, :up, _name}, %{connected?: false} = state) do
    Logger.info("queue notifier connected")
    {:noreply, %{state | connected?: true}}
  end

  def handle_info({:valkey, :up, _name}, state), do: {:noreply, state}

  # T-17
  def handle_info({:valkey, :down}, %{connected?: true} = state) do
    Logger.warning("queue notifier disconnected; the queue polls until Valkey returns")
    :telemetry.execute([:relay, :queue, :notifier, :down], %{count: 1}, %{})
    {:noreply, %{state | connected?: false}}
  end

  def handle_info({:valkey, :down}, state), do: {:noreply, state}

  defp add_channels(state, channels) do
    Enum.reduce(channels, state, fn channel, acc ->
      name = channel_name(acc.conf.prefix, channel)

      if Map.has_key?(acc.channels, name) do
        acc
      else
        _ = Valkey.subscribe(name, acc.adapter)
        put_in(acc.channels[name], channel)
      end
    end)
  end

  defp relay(state, channel, payload) do
    Oban.Notifier.relay(state.conf, channel, payload)
  rescue
    error ->
      Logger.warning("queue notifier dropped an undecodable notification",
        error: inspect(error.__struct__)
      )
  end
end
