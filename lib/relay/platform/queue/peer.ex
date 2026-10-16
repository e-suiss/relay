defmodule Relay.Platform.Queue.Peer do
  @moduledoc """
  Relay's `Oban.Peer`: database leadership over `relay_queue.oban_peers` through `Relay.QueueRepo`, so the application roles never write or delete queue leadership rows (OP-12). A leader renews its lease at half the interval; a failed election gives up leadership until the next one succeeds. On shutdown the leader resigns and asks the other peers to elect.
  """

  @behaviour Oban.Peer

  use GenServer

  alias Relay.Platform.Queue.PeerStore

  require Logger

  @interval 30_000

  defstruct [:conf, :timer, interval: @interval, leader?: false]

  # T-12
  @impl Oban.Peer
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Oban.Peer
  def leader?(pid, timeout \\ 5_000), do: GenServer.call(pid, :leader?, timeout)

  @impl Oban.Peer
  def get_leader(pid, timeout \\ 5_000), do: GenServer.call(pid, :get_leader, timeout)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      conf: Keyword.fetch!(opts, :conf),
      interval: Keyword.get(opts, :interval, @interval)
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    Oban.Notifier.listen(state.conf.name, :leader)
    handle_info(:election, state)
  end

  @impl GenServer
  def handle_info(:election, state) do
    now = naive_now()
    expires_at = NaiveDateTime.add(now, state.interval, :millisecond)

    leader? =
      case PeerStore.elect(name(state), state.conf.node, now, expires_at) do
        {:ok, leader?} -> leader?
        {:error, _reason} -> false
      end

    if leader? != state.leader?,
      do: Logger.info("queue leadership changed", leader: leader?, node: state.conf.node)

    {:noreply, schedule(%{state | leader?: leader?})}
  rescue
    error ->
      Logger.warning("queue leader election failed", error: inspect(error.__struct__))
      {:noreply, schedule(%{state | leader?: false})}
  end

  def handle_info({:notification, :leader, %{"down" => name}}, state) do
    if name == name(state), do: handle_info(:election, state), else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:leader?, _from, state), do: {:reply, state.leader?, state}
  def handle_call(:get_leader, _from, state), do: {:reply, PeerStore.leader(name(state)), state}

  @impl GenServer
  def terminate(_reason, state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)

    if state.leader? do
      :ok = PeerStore.resign(name(state), state.conf.node)
      _ = Oban.Notifier.notify(state.conf, :leader, %{down: name(state)})
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp name(state), do: inspect(state.conf.name)

  defp naive_now, do: Relay.Clock.utc_now() |> DateTime.to_naive()

  defp schedule(state) do
    base = if state.leader?, do: div(state.interval, 2), else: state.interval
    delay = base - Relay.Random.uniform(max(div(base, 10), 1))
    %{state | timer: Process.send_after(self(), :election, delay)}
  end
end
