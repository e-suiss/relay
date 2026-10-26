defmodule Relay.BulkRepo do
  @moduledoc """
  The bulk write pool. It is a second instance of `Relay.Repo`, registered under this name, with its own connections in the same database and the same `relay_worker` login; the OLTP pool `Relay.Repo` keeps serving the critical lanes and the API while the bulk lanes, the DRR dispatcher and fan-out writes run here, so a large fan-out never makes a one-time password insert wait for a connection.

  `run/1` routes every `Relay.Repo` call of the calling process, including the job inserts Oban makes inside its transactions, to this pool for the duration of the function. Because it is the same repository module, the tenant scope discipline of `Relay.Repo` (`in_scope/3`, `scoped_query/3`, the escape hatches) applies unchanged. The startup role check runs against this pool as well.

  Its options are `Relay.Repo`'s with the `config :relay, Relay.BulkRepo` keys applied on top, for example its own `:pool_size`; telemetry events carry the `[:relay, :bulk_repo]` prefix.
  """

  # T-32 (3)
  # T-32 (5)
  @doc "Child specification of the bulk pool."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: Supervisor.child_spec({Relay.Repo, options()}, id: __MODULE__)

  @doc "Start options of the bulk pool."
  @spec options() :: keyword()
  def options do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(name: __MODULE__, telemetry_prefix: [:relay, :bulk_repo])
  end

  # T-32 (3)
  @doc "Runs `fun` with every `Relay.Repo` call of this process going to the bulk pool."
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    previous = Relay.Repo.put_dynamic_repo(__MODULE__)

    try do
      fun.()
    after
      Relay.Repo.put_dynamic_repo(previous)
    end
  end

  @doc "The registered name of the bulk pool, so tools that resolve a repository by module (the SQL sandbox, for one) find it."
  @spec get_dynamic_repo() :: atom()
  def get_dynamic_repo, do: __MODULE__

  @doc "True while the calling process writes through the bulk pool."
  @spec active?() :: boolean()
  def active?, do: Relay.Repo.get_dynamic_repo() == __MODULE__
end
