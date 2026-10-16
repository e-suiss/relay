defmodule Relay.Platform.Valkey.Guard do
  @moduledoc """
  Checks the Valkey eviction policy each time the connection comes up. A policy other than `noeviction` is logged as an error and reported through telemetry; the check never stops the node, since Valkey holds no record of truth.
  """

  use GenServer

  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Key

  require Logger

  @expected "noeviction"
  @retry_ms 1_000

  defstruct [:adapter, :channel, :status]

  @type status :: :unknown | :ok | {:mismatch, String.t()}

  @doc "Starts the guard."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the result of the last eviction policy check."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl GenServer
  def init(opts) do
    adapter = Keyword.get_lazy(opts, :adapter, &Valkey.adapter/0)
    channel = Key.system_channel(["guard"])
    state = %__MODULE__{adapter: adapter, channel: channel, status: :unknown}
    {:ok, state, {:continue, :subscribe}}
  end

  @impl GenServer
  def handle_continue(:subscribe, state) do
    _ = Valkey.subscribe(state.channel, state.adapter)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl GenServer
  def handle_info({:valkey, :up, _channel}, state), do: {:noreply, check(state)}
  def handle_info(:check, state), do: {:noreply, check(state)}
  def handle_info({:valkey, _event}, state), do: {:noreply, state}
  def handle_info({:valkey, _event, _channel, _payload}, state), do: {:noreply, state}

  # T-9 (6)
  defp check(state) do
    case Valkey.eviction_policy(state.adapter) do
      {:ok, @expected} ->
        %{state | status: :ok}

      {:ok, policy} ->
        Logger.error("valkey eviction policy must be noeviction", policy: policy)
        :telemetry.execute([:relay, :valkey, :eviction_policy], %{count: 1}, %{policy: policy})
        %{state | status: {:mismatch, policy}}

      {:error, _error} ->
        Process.send_after(self(), :check, @retry_ms)
        state
    end
  end
end
