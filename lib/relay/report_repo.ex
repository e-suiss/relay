defmodule Relay.ReportRepo do
  @moduledoc """
  The report pool (OP-39). It is a further instance of `Relay.Repo`, registered under this name, with its own connections logged in as `relay_report`: a role that reads the record and rollup tables under row level security and writes nothing, with the long statement timeout of reports. Report reads and raw data exports run here, so a long report never takes a connection of the OLTP pool `Relay.Repo` and never runs with a role that could change a record.

  `run/1` routes every `Relay.Repo` call of the calling process to this pool for the duration of the function, so the tenant scope discipline of `Relay.Repo` (`in_scope/3`, `scoped_query/3`) applies unchanged. A startup role check runs against this pool. Its options are `Relay.Repo`'s with the `config :relay, Relay.ReportRepo` keys applied on top (in production `REPORT_DATABASE_URL` and its password file); telemetry events carry the `[:relay, :report_repo]` prefix. `enabled: false` (the test configuration) runs report reads on the calling process's repository instead.
  """

  @own_keys [:enabled]

  # OP-39
  @doc "Child specification of the report pool."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: Supervisor.child_spec({Relay.Repo, options()}, id: __MODULE__)

  @doc "Start options of the report pool."
  @spec options() :: keyword()
  def options do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.drop(@own_keys)
    |> Keyword.put_new(:username, "relay_report")
    |> Keyword.merge(name: __MODULE__, telemetry_prefix: [:relay, :report_repo])
  end

  @doc "True unless the report pool is turned off in the configuration."
  @spec enabled?() :: boolean()
  def enabled?, do: :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, true)

  # OP-39
  @doc "Runs `fun` with every `Relay.Repo` call of this process going to the report pool."
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    if enabled?(), do: on_pool(fun), else: fun.()
  end

  defp on_pool(fun) do
    previous = Relay.Repo.put_dynamic_repo(__MODULE__)

    try do
      fun.()
    after
      Relay.Repo.put_dynamic_repo(previous)
    end
  end

  @doc "The registered name of the report pool."
  @spec get_dynamic_repo() :: atom()
  def get_dynamic_repo, do: __MODULE__
end
