defmodule Relay.Platform.Concurrency.Keeper do
  @moduledoc """
  The node's keeper of held concurrency slots (T-22). A job that took a slot registers it here; the keeper renews every held lease every 40 seconds while the job lives and releases the slot when the job process exits, normally or by a crash. A node that dies takes the keeper with it and its slots free themselves when their leases end.

  Registration is a synchronous call, so a busy keeper slows the jobs that register instead of letting its mailbox grow (T-45 (4)).
  """

  use GenServer

  alias Relay.Platform.Concurrency

  require Logger

  @type slot :: {Relay.Scope.t(), String.t(), pos_integer(), String.t(), keyword()}

  # T-22
  @doc "Registers a slot the calling process holds; it is renewed until `drop/2` or the process exits."
  @spec hold(slot(), GenServer.server()) :: :ok
  def hold({%Relay.Scope{}, _key, _limit, _holder, _opts} = slot, server \\ __MODULE__),
    do: GenServer.call(server, {:hold, self(), slot})

  @doc "Stops renewing the calling process's slot of `holder` and releases it."
  @spec drop(String.t(), GenServer.server()) :: :ok
  def drop(holder, server \\ __MODULE__), do: GenServer.call(server, {:drop, self(), holder})

  @doc "Lists the holders this keeper renews."
  @spec holders(GenServer.server()) :: [String.t()]
  def holders(server \\ __MODULE__), do: GenServer.call(server, :holders)

  @doc "Starts the keeper. Options: `:name`, `:renew_ms`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    renew_ms = Keyword.get(opts, :renew_ms, Concurrency.renew_ms())
    Process.send_after(self(), :renew, renew_ms)
    {:ok, %{renew_ms: renew_ms, slots: %{}}}
  end

  @impl GenServer
  def handle_call({:hold, pid, {_scope, _key, _limit, holder, _opts} = slot}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.slots[ref], {pid, holder, slot})}
  end

  def handle_call({:drop, pid, holder}, _from, state) do
    {dropped, kept} =
      Map.split_with(state.slots, fn {_ref, {p, h, _slot}} -> p == pid and h == holder end)

    for {ref, {_pid, _holder, slot}} <- dropped do
      Process.demonitor(ref, [:flush])
      release(slot)
    end

    {:reply, :ok, %{state | slots: kept}}
  end

  def handle_call(:holders, _from, state),
    do: {:reply, for({_ref, {_pid, holder, _}} <- state.slots, do: holder), state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.slots, ref) do
      {nil, _slots} ->
        {:noreply, state}

      {{_pid, _holder, slot}, slots} ->
        release(slot)
        {:noreply, %{state | slots: slots}}
    end
  end

  def handle_info(:renew, state) do
    for {_ref, {_pid, _holder, {scope, key, limit, holder, opts}}} <- state.slots do
      case Concurrency.acquire(scope, key, limit, holder, opts) do
        {:ok, _in_use} -> :ok
        {:full, _wait} -> Logger.warning("concurrency lease renewal lost its slot", counter: key)
      end
    end

    Process.send_after(self(), :renew, state.renew_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp release({scope, key, _limit, holder, opts}),
    do: Concurrency.release(scope, key, holder, opts)
end
