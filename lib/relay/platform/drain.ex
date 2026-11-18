defmodule Relay.Platform.Drain do
  @moduledoc """
  The ordered shutdown of a node (OP-87, T-5). It is the last child of the application supervisor, so it is the first to stop when the node receives `SIGTERM`: readiness answers `503 draining` at once, the load balancer gets `:lb_wait_ms` (10 s) to take the node out while requests are still served, then the node's queues stop taking new jobs and the running jobs get up to `:jobs_ms` (30 s) to finish; a job that does not finish stays with its lease and another node takes it over. Only then do the endpoint and its realtime drainer stop (`RelayWeb.Realtime.Drainer`, 15 s), and the process exits. The orchestrator's grace period is 75 s; the order lives here, not in a `preStop` hook.

  Telemetry: `[:relay, :drain, :phase]` with `%{monotonic_ms: ms}` and the `:phase` (`:readiness`, `:queues`, `:jobs`) and, for `:jobs`, the number of jobs still running.
  """

  use GenServer

  require Logger

  @defaults [lb_wait_ms: 10_000, jobs_ms: 30_000, poll_ms: 250]
  @margin_ms 5_000

  @type option ::
          {:name, atom()}
          | {:lb_wait_ms, non_neg_integer()}
          | {:jobs_ms, non_neg_integer()}
          | {:poll_ms, pos_integer()}
          | {:oban, atom() | nil}
          | {:queues, [atom()]}

  # OP-87
  # T-5
  @doc "Child specification; the supervisor waits for the readiness wait and the job drain before it stops the processes started before this one."
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = Keyword.merge(@defaults, opts)

    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: opts[:lb_wait_ms] + opts[:jobs_ms] + @margin_ms
    }
  end

  @doc "Starts the drain coordinator; `:queues` defaults to the node's configured queues on a worker node and none elsewhere."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  # OP-87
  @doc "True once the node named `name` has started to drain; readiness then answers `503`."
  @spec draining?(atom()) :: boolean()
  def draining?(name \\ __MODULE__), do: :persistent_term.get({__MODULE__, name}, false)

  # OP-87
  @doc "Withdraws the node's readiness without stopping anything else."
  @spec withdraw(atom()) :: :ok
  def withdraw(name \\ __MODULE__), do: :persistent_term.put({__MODULE__, name}, true)

  @doc "Restores readiness after a drain that did not end in the node stopping."
  @spec restore(atom()) :: :ok
  def restore(name \\ __MODULE__) do
    _erased = :persistent_term.erase({__MODULE__, name})
    :ok
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    :ok = restore(opts[:name])

    {:ok,
     %{
       name: opts[:name],
       lb_wait_ms: Keyword.fetch!(opts, :lb_wait_ms),
       jobs_ms: Keyword.fetch!(opts, :jobs_ms),
       poll_ms: Keyword.fetch!(opts, :poll_ms),
       oban: Keyword.get(opts, :oban, Oban),
       queues: Keyword.get_lazy(opts, :queues, &local_queues/0)
     }}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :ok = withdraw(state.name)
    phase(:readiness, %{})
    Logger.info("drain: readiness withdrawn")
    Process.sleep(state.lb_wait_ms)
    :ok = pause(state.oban, state.queues)
    phase(:queues, %{})
    Logger.info("drain: queues stopped taking jobs", queues: length(state.queues))
    deadline = Relay.Clock.monotonic_ms() + state.jobs_ms
    running = await(state, deadline)
    phase(:jobs, %{running: running})
    Logger.info("drain: running jobs finished", unfinished: running)
    :ok
  end

  defp local_queues do
    if Relay.Role.enabled?(:worker),
      do: Keyword.keys(Relay.Platform.Lane.queues()),
      else: []
  end

  defp pause(nil, _queues), do: :ok
  defp pause(_oban, []), do: :ok

  defp pause(oban, _queues) do
    Oban.pause_all_queues(oban, local_only: true)
    :ok
  catch
    kind, reason ->
      Logger.warning("drain: queues not paused", reason: Exception.format(kind, reason))
      :ok
  end

  defp await(state, deadline) do
    running = running(state.oban, state.queues)
    left = deadline - Relay.Clock.monotonic_ms()

    if running == 0 or left <= 0 do
      running
    else
      Process.sleep(min(state.poll_ms, left))
      await(state, deadline)
    end
  end

  defp running(nil, _queues), do: 0

  defp running(oban, queues) do
    Enum.reduce(queues, 0, fn queue, acc -> acc + queue_running(oban, queue) end)
  end

  defp queue_running(oban, queue) do
    case Oban.check_queue(oban, queue: queue) do
      %{running: running} when is_list(running) -> length(running)
      _other -> 0
    end
  catch
    _kind, _reason -> 0
  end

  defp phase(phase, measurements) do
    :telemetry.execute(
      [:relay, :drain, :phase],
      Map.put(measurements, :monotonic_ms, Relay.Clock.monotonic_ms()),
      %{phase: phase}
    )
  end
end
