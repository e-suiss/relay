defmodule Relay.Platform.PoolRule do
  @moduledoc """
  The connection pooling rule (OP-30, OP-88), computed once when a node starts. The installation's peak demand is `nodes × pool × 2`: every node's pools, twice over while a rollout runs old and new nodes side by side. Without a pooler it must stay under half of the server's `max_connections`; above that, or with autoscaled nodes, a transaction-mode PgBouncer belongs in front of PostgreSQL. A breach is a warning, never a stop: the node logs it and reports `[:relay, :postgres, :pool_rule]` with `%{exceeded: 0 | 1, demand: n, budget: n}`.

  `nodes` and the pooler come from `config :relay, Relay.Platform.PoolRule` (`RELAY_NODE_COUNT`, `RELAY_DATABASE_POOLER`); the pool is the sum of the pools this node opens.
  """

  require Logger

  @type verdict :: %{exceeded: boolean(), demand: non_neg_integer(), budget: non_neg_integer()}

  # OP-30
  # OP-88
  @doc "Evaluates the rule: `demand = nodes × pool × 2` against `budget = max_connections / 2`; with a pooler in front the rule never warns."
  @spec evaluate(pos_integer(), non_neg_integer(), pos_integer(), boolean()) :: verdict()
  def evaluate(nodes, pool, max_connections, pooler?)
      when is_integer(nodes) and nodes > 0 and is_integer(pool) and pool >= 0 and
             is_integer(max_connections) and max_connections > 0 and is_boolean(pooler?) do
    demand = nodes * pool * 2
    budget = div(max_connections, 2)
    %{exceeded: not pooler? and demand > budget, demand: demand, budget: budget}
  end

  # OP-30
  @doc "The sum of the pool sizes this node opens, read from the repository configuration."
  @spec node_pool() :: non_neg_integer()
  def node_pool do
    worker? = Relay.Role.enabled?(:worker)

    [
      {Relay.Repo, true, 10},
      {Relay.Platform.MaintRepo, true, 2},
      {Relay.ReportRepo, Relay.ReportRepo.enabled?(), 4},
      {Relay.QueueRepo, worker?, 2},
      {Relay.Platform.ArchiveRepo, worker?, 2},
      {Relay.BulkRepo, worker?, pool_size(Relay.Repo, 10)}
    ]
    |> Enum.filter(fn {_repo, open?, _default} -> open? end)
    |> Enum.reduce(0, fn {repo, _open?, default}, sum -> sum + pool_size(repo, default) end)
  end

  # OP-30
  # OP-88
  @doc "Checks the rule with `max_connections` read from the server, logs a breach as a warning and reports the verdict."
  @spec check(pos_integer()) :: verdict()
  def check(max_connections) do
    config = Application.get_env(:relay, __MODULE__, [])
    nodes = Keyword.get(config, :nodes, 1)
    pooler? = Keyword.get(config, :pooler, "none") == "pgbouncer"
    verdict = evaluate(nodes, node_pool(), max_connections, pooler?)
    exceeded = if verdict.exceeded, do: 1, else: 0

    :telemetry.execute(
      [:relay, :postgres, :pool_rule],
      %{exceeded: exceeded, demand: verdict.demand, budget: verdict.budget},
      %{}
    )

    if verdict.exceeded do
      Logger.warning(
        "connection demand exceeds half of max_connections; put a transaction-mode PgBouncer in front of PostgreSQL",
        demand: verdict.demand,
        budget: verdict.budget,
        nodes: nodes
      )
    end

    verdict
  end

  defp pool_size(repo, default) do
    case :relay |> Application.get_env(repo, []) |> Keyword.get(:pool_size) do
      size when is_integer(size) and size >= 0 -> size
      _unset -> default
    end
  end
end
