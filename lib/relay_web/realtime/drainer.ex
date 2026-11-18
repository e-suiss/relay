defmodule RelayWeb.Realtime.Drainer do
  @moduledoc """
  The realtime drainer of the endpoint (IN-34 (4), OP-87). It is the socket's drainer child, so it stops before the HTTP listeners when the endpoint shuts down, which happens only after `Relay.Platform.Drain` has withdrawn readiness and drained the queues. It closes this node's open WebSocket and SSE connections in batches spread over `:window_ms` (15 s), one batch every `:interval_ms` (1 s); each connection gets `{:relay_realtime_drain, seconds}` with its own jittered reconnect hint and closes itself with it (`RelayWeb.Realtime.Transport`, `RelayWeb.Api.RealtimeController`).

  Telemetry: `[:relay, :realtime, :drain]` with `%{connections: n, monotonic_ms: ms}` once the last batch is sent.
  """

  use GenServer

  require Logger

  alias Relay.Realtime.Drain

  @defaults [window_ms: 15_000, interval_ms: 1_000]
  @margin_ms 5_000

  # IN-34
  # OP-87
  @doc "Child specification; the endpoint waits for the whole window before it stops its listeners."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = Keyword.merge(@defaults, opts)

    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: opts[:window_ms] + @margin_ms
    }
  end

  @doc "Starts the drainer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  # IN-34
  # OP-87
  @doc "Closes `connections` in batches over the window and returns how many were asked to close."
  @spec drain([pid()], pos_integer(), pos_integer()) :: non_neg_integer()
  def drain(connections, window_ms, interval_ms) do
    batches = Drain.batches(connections, window_ms, interval_ms)

    batches
    |> Enum.with_index()
    |> Enum.each(fn {batch, index} ->
      if index > 0, do: Process.sleep(interval_ms)
      Enum.each(batch, &send(&1, {:relay_realtime_drain, Drain.reconnect_hint()}))
    end)

    length(connections)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{window_ms: opts[:window_ms], interval_ms: opts[:interval_ms]}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    count = drain(Drain.connections(), state.window_ms, state.interval_ms)

    :telemetry.execute(
      [:relay, :realtime, :drain],
      %{connections: count, monotonic_ms: Relay.Clock.monotonic_ms()},
      %{}
    )

    Logger.info("drain: realtime connections closed", connections: count)
    :ok
  end
end
