defmodule Relay.Platform.Backend do
  @moduledoc """
  Per-node choice between Valkey and the PostgreSQL fallback for limit decisions. The node starts in `valkey`. A failed Valkey call, or one slower than 250 ms, moves it to `pg`; it stays there at least 5 seconds and then sends `PING` once a second. A successful `PING` records the recovery time and returns the node to Valkey, but a key stays `dual` until the recovery time plus that key's horizon: in `dual` a decision is taken and consumed on both backends and allowed only if both allow. There is never an unlimited branch; when neither backend answers the caller denies with `deny_reason/0`.

  The state is a pure value (`new/0`, `failure/2`, `recover/2`, `mode/3`); the server holds the node's state, publishes it for lock-free reads and runs the `PING` timer. Time is the node's monotonic clock. Every change of phase is reported as `[:relay, :backend, :mode]` telemetry (`pg` is 1 while the node is on PostgreSQL); entering `pg` is logged as an error and the recovery that opens `dual` as a warning.
  """

  use GenServer

  alias Relay.Platform.Valkey

  require Logger

  @slow_ms 250
  @hold_ms 5_000
  @ping_ms 1_000
  @deny_retry_after_ms 1_000
  @deny_rule_id "rate_limit.backend_unavailable"

  @enforce_keys [:phase]
  defstruct phase: :valkey, since: nil, recovered_at: nil

  @type mode :: :valkey | :pg | :dual
  @type t :: %__MODULE__{
          phase: :valkey | :pg,
          since: integer() | nil,
          recovered_at: integer() | nil
        }

  # T-9 (5)
  @doc "The initial state: Valkey, with no recovery in progress."
  @spec new() :: t()
  def new, do: %__MODULE__{phase: :valkey}

  @doc "Records a failed or slow Valkey call at monotonic time `now_ms`; a node already on `pg` keeps its start time."
  @spec failure(t(), integer()) :: t()
  def failure(%__MODULE__{phase: :pg} = state, _now_ms), do: state

  def failure(%__MODULE__{}, now_ms) when is_integer(now_ms),
    do: %__MODULE__{phase: :pg, since: now_ms, recovered_at: nil}

  @doc "Records a successful `PING` at `now_ms`; only a `pg` state changes."
  @spec recover(t(), integer()) :: t()
  def recover(%__MODULE__{phase: :pg}, now_ms) when is_integer(now_ms),
    do: %__MODULE__{phase: :valkey, since: nil, recovered_at: now_ms}

  def recover(%__MODULE__{} = state, _now_ms), do: state

  # T-9 (5)
  # INV-44
  @doc "The backend mode at `now_ms` for a key whose decisions last `horizon_ms`."
  @spec mode(t(), integer(), non_neg_integer()) :: mode()
  def mode(%__MODULE__{phase: :pg}, _now_ms, _horizon_ms), do: :pg

  def mode(%__MODULE__{recovered_at: nil}, _now_ms, _horizon_ms), do: :valkey

  def mode(%__MODULE__{recovered_at: at}, now_ms, horizon_ms)
      when is_integer(now_ms) and is_integer(horizon_ms) and horizon_ms >= 0,
      do: if(now_ms < at + horizon_ms, do: :dual, else: :valkey)

  @doc "Returns true if a Valkey call with this result and duration moves the node to `pg`."
  @spec failed?(term(), non_neg_integer()) :: boolean()
  def failed?({:error, _reason}, _elapsed_ms), do: true
  def failed?(_result, elapsed_ms), do: elapsed_ms > @slow_ms

  # T-9 (5)
  @doc "The denial used when neither backend answers: retry after 1 second, rule `rate_limit.backend_unavailable`."
  @spec deny_reason() :: %{retry_after_ms: pos_integer(), rule_id: String.t()}
  def deny_reason, do: %{retry_after_ms: @deny_retry_after_ms, rule_id: @deny_rule_id}

  @doc "Starts the node's backend server. Options: `:name`, `:adapter`, `:clock`, `:hold_ms`, `:ping_ms`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  # T-9 (5)
  @doc "The node's backend mode now for a key with `horizon_ms`; reads the published state without calling the server."
  @spec current_mode(non_neg_integer(), GenServer.name()) :: mode()
  def current_mode(horizon_ms, server \\ __MODULE__),
    do: mode(state(server), clock(server).monotonic_ms(), horizon_ms)

  @doc "The node's published state."
  @spec state(GenServer.name()) :: t()
  def state(server \\ __MODULE__), do: :persistent_term.get({__MODULE__, server}, new())

  @doc "Runs a Valkey call, measures it and reports a failed or slow call; the call's result is returned unchanged."
  @spec call_valkey((-> result), GenServer.name()) :: result when result: term()
  def call_valkey(fun, server \\ __MODULE__) when is_function(fun, 0) do
    clock = clock(server)
    started = clock.monotonic_ms()
    result = fun.()
    if failed?(result, clock.monotonic_ms() - started), do: report_failure(server)
    result
  end

  @doc "Reports a failed or slow Valkey call."
  @spec report_failure(GenServer.name()) :: :ok
  def report_failure(server \\ __MODULE__) do
    if state(server).phase == :pg, do: :ok, else: GenServer.cast(server, :failure)
  end

  @impl GenServer
  def init(opts) do
    server = Keyword.fetch!(opts, :name)
    clock = Keyword.get(opts, :clock, Relay.Clock)
    :persistent_term.put({__MODULE__, :clock, server}, clock)

    config = %{
      server: server,
      adapter: Keyword.get_lazy(opts, :adapter, &Valkey.adapter/0),
      clock: clock,
      hold_ms: Keyword.get(opts, :hold_ms, @hold_ms),
      ping_ms: Keyword.get(opts, :ping_ms, @ping_ms)
    }

    publish(config, new())
    {:ok, {config, new()}}
  end

  @impl GenServer
  def handle_cast(:failure, {config, %__MODULE__{phase: :pg} = state}),
    do: {:noreply, {config, state}}

  def handle_cast(:failure, {config, state}) do
    next = failure(state, config.clock.monotonic_ms())
    publish(config, next)
    Logger.error("valkey unavailable; limit decisions use PostgreSQL")
    Process.send_after(self(), :ping, config.hold_ms)
    {:noreply, {config, next}}
  end

  @impl GenServer
  def handle_info(:ping, {config, %__MODULE__{phase: :pg} = state}) do
    case Valkey.ping(config.adapter) do
      :ok ->
        next = recover(state, config.clock.monotonic_ms())
        publish(config, next)
        Logger.warning("valkey reachable again; limit decisions run on both backends")
        {:noreply, {config, next}}

      {:error, _error} ->
        Process.send_after(self(), :ping, config.ping_ms)
        {:noreply, {config, state}}
    end
  end

  def handle_info(_message, data), do: {:noreply, data}

  defp publish(config, state) do
    :persistent_term.put({__MODULE__, config.server}, state)

    :telemetry.execute(
      [:relay, :backend, :mode],
      %{pg: if(state.phase == :pg, do: 1, else: 0)},
      %{phase: state.phase, recovered_at: state.recovered_at}
    )
  end

  defp clock(server), do: :persistent_term.get({__MODULE__, :clock, server}, Relay.Clock)
end
