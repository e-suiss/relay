defmodule Relay.Keys.Eviction do
  @moduledoc """
  Drops unwrapped keys from every node's cache when a key is destroyed or restricted. `notify/0` flushes this node's cache and publishes a signal on the system topic `keys:changed`; the server on every node flushes its cache on each signal, and also on every re-read tick, which the signal hub sends right after the subscription is confirmed and repeatedly while Valkey is unavailable, so a node that cannot hear destructions keeps no key for long.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Platform, Relay.Tenancy], exports: []
  use GenServer

  require Logger

  # TN-66 (2)
  @doc "The system signal topic of key destructions."
  @spec topic() :: String.t()
  def topic, do: Relay.Platform.system_signal_topic(["keys", "changed"])

  # TN-66 (2)
  # OP-17
  @doc "Flushes this node's key cache and tells the other nodes to flush theirs; call it after the transaction that destroyed or restricted a key commits."
  @spec notify() :: :ok
  def notify do
    :ok = Relay.Tenancy.flush_key_cache()
    seq = DateTime.to_unix(Relay.Clock.utc_now(), :microsecond)

    case Relay.Platform.publish_signal(topic(), seq) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning("key destruction signal not published", code: error.code)
        :ok
    end
  end

  @doc "Starts the server that flushes this node's cache on every key destruction signal."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @impl GenServer
  def init(:ok) do
    :ok = Relay.Platform.subscribe_signal(topic())
    {:ok, nil}
  end

  @impl GenServer
  def handle_info({:relay_signal, _topic, _event}, state) do
    :ok = Relay.Tenancy.flush_key_cache()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
