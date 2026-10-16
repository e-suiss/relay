defmodule Relay.Platform.OutboxDispatcher do
  @moduledoc """
  The worker node's outbox loop. It wakes on the outbox signal and in any case every poll interval, and dispatches one batch for each scope with pending rows. Several dispatchers may run at once; claiming with `SKIP LOCKED` keeps them apart.
  """

  use GenServer

  alias Relay.Platform.Outbox
  alias Relay.Platform.Signal

  require Logger

  @poll_ms 1_000

  @doc "Starts the dispatcher; options are passed to `Relay.Platform.Outbox.run_once/1`, plus `:poll_ms`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    :ok = Signal.subscribe(Outbox.wake_topic())

    state = %{
      opts: Keyword.delete(opts, :poll_ms),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms)
    }

    {:ok, schedule(state)}
  end

  # T-86
  @impl GenServer
  def handle_info(:tick, state) do
    drain(state)
    {:noreply, schedule(state)}
  end

  def handle_info({:relay_signal, _topic, _event}, state) do
    drain(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp drain(state) do
    _ = Outbox.run_once(state.opts)
    :ok
  rescue
    error ->
      Logger.error("outbox dispatch failed", error: inspect(error.__struct__))
      :ok
  end

  defp schedule(state) do
    Process.send_after(self(), :tick, state.poll_ms)
    state
  end
end
