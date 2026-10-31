defmodule Relay.Platform.Capacity.Sampler do
  @moduledoc """
  Keeps this node's view of the bulk lane capacities current: it samples `relay_ops.lane_capacity` at start and every 5 s and puts the result into the node's capacity table, which it owns (`Relay.Platform.Capacity`). A failed sample keeps the last known capacities. Runs on every node unless `config :relay, Relay.Platform.Capacity, sampler: false`.
  """

  use GenServer

  require Logger

  alias Relay.Platform.Capacity

  @poll_ms 5_000

  # T-35 (2)
  @doc "Starts the sampler; `:poll_ms` overrides the five-second poll."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    :ok = Capacity.table()
    send(self(), :poll)
    {:ok, %{poll_ms: Keyword.get(opts, :poll_ms, @poll_ms)}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    case Capacity.sample() do
      {:ok, _capacity} -> :ok
      {:error, error} -> Logger.debug("lane capacity unreadable", code: error.code)
    end

    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state}
  end
end
