defmodule Relay.Repo do
  @moduledoc """
  The PostgreSQL repository. Only `*.Store` modules call it (T-60).

  Every tenant-scoped transaction goes through `in_scope/3`, which establishes the tenant and environment with `relay_fn.ctx_set` as the transaction's first statement. Tenant-scoped SQL goes through `scoped_query/3`, which refuses to run outside such a transaction and checks that every returned row belongs to the scope. Ecto queries without a scope are refused as well, except the job queue's own queries and the migrator's. Cross-tenant calls are allowed only through `unscoped_query/4` with a declared escape hatch.
  """

  use Ecto.Repo, otp_app: :relay, adapter: Ecto.Adapters.Postgres

  alias Ecto.Multi
  alias Relay.Scope
  alias Relay.ScopeError

  @scope_key {__MODULE__, :scope}
  @escapes [
    :tenant_bootstrap,
    :outbox_scope_discovery,
    :installation_lookup,
    :fair_dispatch,
    :load_shed,
    :dead_letter_scope_discovery,
    :kill_switch_snapshot,
    :kill_switch_scopes,
    :waitpoint_due_discovery,
    :access_link,
    :access_event_intake,
    :api_client_resolve,
    :operator_access,
    :cross_tenant_overview,
    :suspension_due_discovery
  ]

  @type tenant_status :: :active | :suspended | :closed
  @type escape ::
          :tenant_bootstrap
          | :outbox_scope_discovery
          | :installation_lookup
          | :fair_dispatch
          | :load_shed
          | :dead_letter_scope_discovery
          | :kill_switch_snapshot
          | :kill_switch_scopes
          | :waitpoint_due_discovery
          | :access_link
          | :access_event_intake
          | :api_client_resolve
          | :operator_access
          | :cross_tenant_overview
          | :suspension_due_discovery

  # TN-13 (4)
  @impl Ecto.Repo
  def prepare_query(_operation, query, opts) do
    if opts[:oban] == true or opts[:schema_migration] == true or current_scope() != nil,
      do: {query, opts},
      else: raise(ScopeError, :missing)
  end

  # TN-13 (2)
  # TN-13 (4)
  # TN-13 (5)
  # T-57 (4)
  @doc """
  Runs `fun` in one transaction whose first statement establishes `scope`; `fun` receives the tenant status.

  A tenant the scope cannot see returns `{:error, %Relay.Error{code: :not_found}}` (TN-15). The context is never inherited: calling this inside another transaction or another scope raises.
  """
  @spec in_scope(Scope.t(), (tenant_status() -> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def in_scope(%Scope{} = scope, fun, opts \\ []) when is_function(fun, 1) do
    enter!(scope)

    try do
      transaction(
        fn ->
          case establish(scope) do
            {:ok, status} -> fun.(status)
            {:error, :tenant_not_found} -> rollback(:tenant_not_found)
          end
        end,
        opts
      )
      |> not_found()
    after
      leave()
    end
  end

  # TN-13 (2)
  # T-57 (4)
  @doc "Runs a multi in one transaction whose first step establishes `scope`; its changes also carry `:tenant_status`. See `in_scope/3`."
  @spec in_scope_multi(Scope.t(), Multi.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:error, Multi.name(), term(), map()}
  def in_scope_multi(%Scope{} = scope, multi, opts \\ []) do
    enter!(scope)

    try do
      scope
      |> scoped_multi(multi)
      |> transaction(opts)
      |> not_found()
    after
      leave()
    end
  end

  @dialyzer {:no_opaque, scoped_multi: 2}
  defp scoped_multi(scope, multi) do
    Multi.new()
    |> Multi.run(:tenant_status, fn _repo, _changes -> establish(scope) end)
    |> Multi.append(multi)
  end

  @doc "Returns the scope established in this process, or nil outside a scoped transaction."
  @spec current_scope() :: Scope.t() | nil
  def current_scope do
    case Process.get(@scope_key) do
      %Scope{} = scope -> if in_transaction?(), do: scope
      nil -> nil
    end
  end

  # TN-13 (4)
  # TN-16 (3)
  # sobelow_skip ["SQL.Query"]
  @doc """
  Runs tenant-scoped SQL inside `in_scope/3`; raises `Relay.ScopeError` without a scope or for a row outside it.

  With `shared: :installation`, rows of the installation tenant's `live` environment are also accepted: installation-wide data sets are readable from every scope (S-3).
  """
  @spec scoped_query(iodata(), [term()], keyword()) ::
          {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  def scoped_query(sql, params, opts \\ []) do
    scope = scope!()
    {shared, opts} = Keyword.pop(opts, :shared)

    case query(sql, params, opts) do
      {:ok, result} -> {:ok, check_rows!(scope, result, shared_scopes(shared))}
      {:error, error} -> {:error, error}
    end
  end

  # sobelow_skip ["SQL.Query"]
  @doc "Like `scoped_query/3`, raising on a database error."
  @spec scoped_query!(iodata(), [term()], keyword()) :: Postgrex.Result.t()
  def scoped_query!(sql, params, opts \\ []) do
    scope = scope!()
    {shared, opts} = Keyword.pop(opts, :shared)
    check_rows!(scope, query!(sql, params, opts), shared_scopes(shared))
  end

  # TN-13 (4)
  # OP-68 (9)
  # sobelow_skip ["SQL.Query"]
  @doc """
  Runs SQL that crosses tenants through a `relay_ops` escape hatch. The escape names why: `:tenant_bootstrap` creates a tenant before any context can exist, `:outbox_scope_discovery` lists the scopes that have pending outbox rows, without content, `:installation_lookup` reads the installation tenant's identifier, which installation-wide data sets are scoped to (S-3), `:fair_dispatch` lets the DRR dispatcher move waiting jobs of every tenant of a bulk lane into the queue and refresh their weights, by identifiers only, `:load_shed` records and reads the installation-wide load shedding transitions. `:kill_switch_snapshot` reads the full set of kill switch records in force (TN-39) and `:kill_switch_scopes` lists the scopes a platform kill switch's sweep, bulk cancel or the paused expiry visits, by identifier only. `:waitpoint_due_discovery` lists the scopes that have a waitpoint timer due, without content (S-61). `:access_link` reads and writes the installation's Access link cache (E-78), `:access_event_intake` records and applies Access event receipts and maps an Access tenant to its Relay tenant (S-69), and `:api_client_resolve` resolves an Access client of a token to its tenant, environment and API client trace before any tenant context exists (S-72). `:operator_access` signs operators in, resolves, steps up and revokes their sessions, reflects their Access lifecycle and lists their role grants and support delegations across tenants before any tenant context exists (S-76, S-77). `:cross_tenant_overview` reads installation-level facts and counters of every tenant, never record content (X-4). `:suspension_due_discovery` lists the scheduled suspensions that are due, by identifier only (TN-71).
  """
  @spec unscoped_query(escape(), iodata(), [term()], keyword()) ::
          {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  def unscoped_query(escape, sql, params, opts \\ []) do
    unless escape in @escapes, do: raise(ScopeError, :unknown_escape)
    if Process.get(@scope_key), do: raise(ScopeError, :nested)
    query(sql, params, opts)
  end

  # OP-8
  @doc """
  Calls a `relay_fn` database function inside `in_scope/3` with positional parameters and returns its rows as maps keyed by column name. A scalar function returns one row keyed by the function's name.
  """
  @spec call!(String.t(), [term()]) :: [%{String.t() => term()}]
  def call!(function, params) when is_list(params) do
    function |> function_sql("relay_fn", params) |> scoped_query!(params) |> maps()
  end

  @doc "Calls a `relay_ops` escape hatch function; see `unscoped_query/4`."
  @spec call_unscoped!(escape(), String.t(), [term()]) :: [%{String.t() => term()}]
  def call_unscoped!(escape, function, params) when is_list(params) do
    sql = function_sql(function, "relay_ops", params)

    case unscoped_query(escape, sql, params) do
      {:ok, result} -> maps(result)
      {:error, error} -> raise error
    end
  end

  # C-4
  @doc "Decodes a result code from a function's closed result set; an unknown code is a contract violation and raises."
  @spec code!(String.t(), [atom(), ...]) :: atom()
  def code!(text, codes) when is_binary(text) and is_list(codes) do
    Enum.find(codes, &(Atom.to_string(&1) == text)) ||
      raise ArgumentError, "result #{inspect(text)} is outside #{inspect(codes)}"
  end

  defp function_sql(function, schema, params) do
    unless String.starts_with?(function, schema <> ".") and
             Regex.match?(~r/\A[a-z_]+\.[a-z_]+\z/, function),
           do: raise(ArgumentError, "not a #{schema} function: #{inspect(function)}")

    placeholders = Enum.map_join(1..length(params)//1, ", ", &"$#{&1}")
    "SELECT * FROM #{function}(#{placeholders})"
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))

  @doc "Returns the escape hatches `unscoped_query/4` accepts."
  @spec escapes() :: [escape(), ...]
  def escapes, do: @escapes

  defp enter!(scope) do
    cond do
      Process.get(@scope_key) != nil -> raise ScopeError, :nested
      in_transaction?() -> raise ScopeError, :not_first
      true -> Process.put(@scope_key, scope)
    end
  end

  defp leave, do: Process.delete(@scope_key)

  defp scope! do
    case current_scope() do
      %Scope{} = scope -> scope
      nil -> raise ScopeError, :missing
    end
  end

  defp establish(%Scope{tenant_id: tenant_id, environment: environment}) do
    case query("SELECT relay_fn.ctx_set($1, $2)", [
           tenant_id,
           Relay.Environment.dump(environment)
         ]) do
      {:ok, %{rows: [[status]]}} -> {:ok, tenant_status(status)}
      {:error, %Postgrex.Error{} = error} -> tenant_not_found(error)
    end
  end

  defp tenant_status("active"), do: :active
  defp tenant_status("suspended"), do: :suspended
  defp tenant_status("closed"), do: :closed

  defp tenant_not_found(%Postgrex.Error{postgres: %{message: message}} = error) do
    if message =~ "tenant_not_found",
      do: {:error, :tenant_not_found},
      else: raise(error)
  end

  defp tenant_not_found(error), do: raise(error)

  # TN-15
  defp not_found({:error, :tenant_status, :tenant_not_found, _changes}), do: not_found_error()
  defp not_found({:error, :tenant_not_found}), do: not_found_error()
  defp not_found(result), do: result

  defp not_found_error, do: {:error, Relay.Error.new(:not_found, "not found")}

  # TN-16 (3)
  @doc "Returns the result if every row's `tenant_id` and `environment` columns belong to `scope` or to one of the `shared` scopes; raises `Relay.ScopeError` otherwise."
  @spec check_rows!(Scope.t(), Postgrex.Result.t(), [Scope.t()]) :: Postgrex.Result.t()
  def check_rows!(scope, result, shared \\ [])

  def check_rows!(scope, %Postgrex.Result{columns: columns, rows: rows} = result, shared)
      when is_list(columns) and is_list(rows) do
    tenant = Enum.find_index(columns, &(&1 == "tenant_id"))
    environment = Enum.find_index(columns, &(&1 == "environment"))
    allowed = Enum.map([scope | shared], &{&1.tenant_id, Relay.Environment.dump(&1.environment)})

    unless Enum.all?(rows, &row_allowed?(&1, tenant, environment, allowed)),
      do: raise(ScopeError, :row_outside_scope)

    result
  end

  def check_rows!(_scope, result, _shared), do: result

  defp row_allowed?(row, tenant, environment, allowed) do
    Enum.any?(allowed, fn {tenant_id, env} ->
      column_is?(row, tenant, tenant_id) and column_is?(row, environment, env)
    end)
  end

  defp column_is?(_row, nil, _expected), do: true
  defp column_is?(row, index, expected), do: Enum.at(row, index) == expected

  defp shared_scopes(nil), do: []

  defp shared_scopes(:installation) do
    %{rows: [[installation]]} = query!("SELECT relay_private.installation_tenant_id()", [])
    [%Scope{tenant_id: installation, environment: :live}]
  end
end
