defmodule Relay.Platform.LoadShed.Watcher do
  @moduledoc """
  Keeps this node's view of load shedding current. It reads the last transition of every lane from `relay_ops.load_shed_state` when the `relay:s:signal:load_shed` signal arrives and, since a signal can be lost, once a second regardless, and puts the engaged lanes into `:persistent_term` when they change. A failed read keeps the last known state. Runs on every node unless `config :relay, Relay.Platform.LoadShed, watcher: false`.
  """

  use GenServer

  require Logger

  alias Relay.Platform.Lane
  alias Relay.Platform.LoadShed
  alias Relay.Platform.LoadShed.Control
  alias Relay.Platform.LoadShed.Store
  alias Relay.Platform.Signal

  @poll_ms 1_000

  # T-86
  # T-34
  @doc "Starts the watcher; `:poll_ms` overrides the one-second poll."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Reads the state now."
  @spec refresh() :: :ok
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  @doc "Converts `relay_ops.load_shed_state` rows to the engaged lanes."
  @spec engaged([map()]) :: %{Lane.t() => boolean()}
  def engaged(rows) do
    Enum.reduce(rows, Map.new(Lane.all(), &{&1, false}), fn row, acc ->
      case Lane.lane_of_queue(row["lane"]) do
        nil -> acc
        lane -> Map.put(acc, lane, row["phase"] == "engaged")
      end
    end)
  end

  @impl GenServer
  def init(opts) do
    :ok = Signal.subscribe(Control.topic())
    send(self(), :poll)
    {:ok, %{poll_ms: Keyword.get(opts, :poll_ms, @poll_ms)}}
  end

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    read()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    read()
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state}
  end

  def handle_info({:relay_signal, _topic, _event}, state) do
    read()
    {:noreply, state}
  end

  defp read do
    case Store.state() do
      {:ok, rows} -> LoadShed.put_engaged(engaged(rows))
      {:error, error} -> Logger.debug("load shedding state unreadable", code: error.code)
    end
  end
end
