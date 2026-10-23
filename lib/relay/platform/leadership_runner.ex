defmodule Relay.Platform.Leadership.Runner do
  @moduledoc """
  Runs one singleton task on this node while it holds the task's lease. On each tick the runner takes or renews the lease; as leader it runs the task when the task's delay has passed and saves the returned state under its fencing token, as follower it only watches. Losing the lease, a refused save or a failing database drops the cached state, so the next leadership starts from what is saved. The leaderless alarm is the telemetry event `[:relay, :leadership, :leaderless]` and an error log.
  """

  use GenServer

  require Logger

  alias Relay.Platform.Leadership
  alias Relay.Platform.Leadership.Store

  @retry_ms 5_000

  @type option ::
          {:name, String.t()}
          | {:module, module()}
          | {:node, String.t()}
          | {:ttl_ms, pos_integer()}
          | {:retry_ms, pos_integer()}
          | {:server, GenServer.name()}

  # T-12
  @doc "Starts the runner of task `:name` implemented by `:module`."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, server} -> GenServer.start_link(__MODULE__, opts, name: server)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Runs one tick now and returns the runner's role: `:leader`, `:follower` or `:unknown`."
  @spec tick(GenServer.server()) :: :leader | :follower | :unknown
  def tick(server), do: GenServer.call(server, :tick, :infinity)

  @impl GenServer
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name),
      module: Keyword.fetch!(opts, :module),
      node: Keyword.get_lazy(opts, :node, &Leadership.node_id/0),
      ttl_ms: Keyword.get(opts, :ttl_ms, Leadership.default_ttl_ms()),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      token: nil,
      saved: nil,
      due_ms: Relay.Clock.monotonic_ms(),
      last_seen_ms: Relay.Clock.monotonic_ms(),
      alarmed: false,
      role: :unknown,
      timer: nil
    }

    {:ok, schedule(state, 0)}
  end

  @impl GenServer
  def handle_call(:tick, _from, state) do
    state = step(cancel(state))
    {:reply, state.role, state}
  end

  @impl GenServer
  def handle_info(:tick, state), do: {:noreply, step(%{state | timer: nil})}

  defp step(state) do
    now = Relay.Clock.monotonic_ms()

    state
    |> acquire(now)
    |> alarm(now)
  end

  defp acquire(state, now) do
    with {:ok, result, token} <- Store.acquire(state.name, state.node, state.ttl_ms),
         {:lead, token, fresh?} <- Leadership.interpret(result, token, state.token) do
      lead(%{seen(state) | last_seen_ms: now, role: :leader}, token, fresh?, now)
    else
      :follow ->
        schedule(
          %{forget(seen(state)) | last_seen_ms: now, role: :follower},
          state.retry_ms
        )

      {:error, error} ->
        Logger.warning("singleton lease unavailable", task: state.name, code: error.code)
        schedule(%{forget(state) | role: :unknown}, state.retry_ms)
    end
  end

  defp lead(state, token, fresh?, now) do
    case if(fresh?, do: Store.load_state(state.name), else: {:ok, state.saved}) do
      {:ok, saved} ->
        state = %{state | token: token, saved: saved}

        if now >= state.due_ms,
          do: run(state, now),
          else: schedule(state, Leadership.next_tick_ms(state.due_ms - now, state.ttl_ms))

      {:error, _error} ->
        schedule(forget(state), state.retry_ms)
    end
  end

  defp run(state, now) do
    context = %{
      name: state.name,
      node: state.node,
      fencing_token: state.token,
      state: state.saved
    }

    case safe_run(state.module, context) do
      {:ok, saved, delay} when is_map(saved) and is_integer(delay) and delay > 0 ->
        save(state, saved, delay, now)

      :not_leader ->
        schedule(%{forget(state) | role: :unknown}, state.retry_ms)

      {:error, error} ->
        Logger.error("singleton task step failed", task: state.name, code: error.code)
        schedule(%{state | due_ms: now + state.retry_ms}, state.retry_ms)
    end
  end

  defp save(state, saved, delay, now) do
    case Store.save(state.name, state.token, saved) do
      {:ok, "saved"} ->
        state = %{state | saved: saved, due_ms: now + delay}
        schedule(state, Leadership.next_tick_ms(delay, state.ttl_ms))

      _other ->
        schedule(%{forget(state) | role: :unknown}, state.retry_ms)
    end
  end

  defp safe_run(module, context) do
    module.run(context)
  rescue
    exception ->
      Logger.error("singleton task raised",
        task: context.name,
        exception: inspect(exception.__struct__)
      )

      {:error, Relay.Error.new(:task_raised, "singleton task raised")}
  end

  defp alarm(%{alarmed: false} = state, now) do
    if Leadership.leaderless?(state.last_seen_ms, now) do
      :telemetry.execute(
        [:relay, :leadership, :leaderless],
        %{duration_ms: now - state.last_seen_ms},
        %{task: state.name}
      )

      :telemetry.execute([:relay, :leadership, :state], %{leaderless: 1}, %{task: state.name})
      Logger.error("singleton task has no leader", task: state.name)
      %{state | alarmed: true}
    else
      state
    end
  end

  defp alarm(state, _now), do: state

  # OP-69
  defp seen(%{alarmed: true} = state) do
    :telemetry.execute([:relay, :leadership, :state], %{leaderless: 0}, %{task: state.name})
    %{state | alarmed: false}
  end

  defp seen(state), do: state

  defp forget(state), do: %{state | token: nil, saved: nil}

  defp schedule(state, delay), do: %{state | timer: Process.send_after(self(), :tick, delay)}

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(%{timer: timer} = state) do
    _ = Process.cancel_timer(timer)

    receive do
      :tick -> :ok
    after
      0 -> :ok
    end

    %{state | timer: nil}
  end
end
