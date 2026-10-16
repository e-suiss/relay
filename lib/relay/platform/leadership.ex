defmodule Relay.Platform.Leadership do
  @moduledoc """
  Database-led singleton tasks. Each task named in `singleton_tasks` runs on the one worker node that holds its lease; the lease is taken and renewed through `relay_ops.singleton_acquire` on the database clock, a change of leader increments the fencing token, and every write of the task carries that token so that a former leader's write is refused. The task's progress lives in the database, so a new leader continues where the old one stopped. A task that stays without a leader for five minutes raises an alarm.

  A task implements this behaviour: `run/1` receives the task name, the fencing token and the saved state, does one step and returns the state to save and the delay before its next step.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Platform.MaintRepo], exports: []

  alias Relay.Platform.Leadership.Runner

  @type context :: %{
          name: String.t(),
          node: String.t(),
          fencing_token: pos_integer(),
          state: map() | nil
        }

  @type step :: {:ok, map(), pos_integer()} | :not_leader | {:error, Relay.Error.t()}

  @callback run(context()) :: step()

  @leaderless_ms 5 * 60_000
  @default_ttl_ms 30_000

  # T-12
  @doc "Leaderless time after which an alarm is raised, in milliseconds."
  @spec leaderless_ms() :: pos_integer()
  def leaderless_ms, do: @leaderless_ms

  @doc "Returns true if no leader was observed for longer than the alarm threshold."
  @spec leaderless?(integer(), integer()) :: boolean()
  def leaderless?(last_seen_ms, now_ms) when is_integer(last_seen_ms) and is_integer(now_ms),
    do: now_ms - last_seen_ms > @leaderless_ms

  @doc """
  Interprets a `singleton_acquire` result for a node: `{:lead, token, fresh?}` where `fresh?` is true when this node has just become leader (or the token changed under it) and must reload the saved state, or `:follow` when another node holds a live lease.
  """
  @spec interpret(String.t(), pos_integer() | nil, pos_integer() | nil) ::
          {:lead, pos_integer(), boolean()} | :follow
  def interpret("acquired", token, _previous) when is_integer(token), do: {:lead, token, true}
  def interpret("renewed", token, token) when is_integer(token), do: {:lead, token, false}
  def interpret("renewed", token, _previous) when is_integer(token), do: {:lead, token, true}
  def interpret("held_by_other", _token, _previous), do: :follow

  @doc "Delay before the next tick: the task's own delay, but never longer than a third of the lease."
  @spec next_tick_ms(pos_integer(), pos_integer()) :: pos_integer()
  def next_tick_ms(task_delay_ms, ttl_ms)
      when is_integer(task_delay_ms) and task_delay_ms > 0 and is_integer(ttl_ms) and ttl_ms > 0,
      do: min(task_delay_ms, max(div(ttl_ms, 3), 1))

  @doc "Reads the saved state of a task, `nil` if it never saved one."
  @spec saved_state(String.t()) :: {:ok, map() | nil} | {:error, Relay.Error.t()}
  def saved_state(name) when is_binary(name), do: Relay.Platform.Leadership.Store.load_state(name)

  @doc "Lease length used when a task does not configure one, in milliseconds."
  @spec default_ttl_ms() :: pos_integer()
  def default_ttl_ms, do: @default_ttl_ms

  # T-12
  # T-3
  @doc """
  Supervised children for the roles of this node: the maintenance repository and one runner per configured task, only on `worker` nodes and only when `config :relay, Relay.Platform.Leadership, enabled: true`.
  """
  @spec children([Relay.Role.t()]) :: [Supervisor.child_spec()]
  def children(roles) when is_list(roles) do
    config = Application.get_env(:relay, __MODULE__, [])

    if :worker in roles and Keyword.get(config, :enabled, false) do
      node = node_id()

      runners =
        for {name, module, opts} <- Keyword.get(config, :tasks, []) do
          Supervisor.child_spec(
            {Runner, Keyword.merge(opts, name: name, module: module, node: node)},
            id: {Runner, name}
          )
        end

      [Supervisor.child_spec(Relay.Platform.MaintRepo, []) | runners]
    else
      []
    end
  end

  @doc "Identifies this node instance in the leadership table: host name plus a random instance id."
  @spec node_id() :: String.t()
  def node_id do
    {:ok, host} = :inet.gethostname()
    "#{host}/#{Base.encode16(Relay.Random.bytes(6), case: :lower)}"
  end
end
