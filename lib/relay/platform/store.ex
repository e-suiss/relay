defmodule Relay.Platform.Store do
  @moduledoc """
  Database access of the platform: the readiness probe, the startup role check and the query statistics check. A node whose database login is privileged, owns objects, may remove rows, writes the record tables directly, runs on an unsupported PostgreSQL or finds a preset tenant context refuses to start.
  """

  require Logger

  alias Relay.Repo

  @type query_fun :: (String.t(), list() -> {:ok, [[term()]]} | {:error, term()})
  @type profile :: {:app, [Relay.Role.t()]} | :queue
  @type violation ::
          :privileged_role
          | :owns_objects
          | :delete_or_truncate
          | :writes_record_tables
          | :outside_queue_schema
          | :role_switched
          | :wrong_login_role
          | :unsupported_postgres
          | :row_security_off
          | :statement_timeout
          | :tenant_context_preset
  @type facts :: %{
          roles: [{String.t(), boolean(), boolean()}],
          owned: [String.t()],
          tables: [{String.t(), String.t(), [String.t()]}],
          schemas: [{String.t(), boolean()}],
          current_user: String.t(),
          session_user: String.t(),
          server_version_num: integer(),
          server_version: String.t(),
          row_security: String.t(),
          statement_timeout_ms: integer(),
          context_settings: [String.t()]
        }

  @logins %{api: "relay_api", socket: "relay_api", worker: "relay_worker"}
  @statement_timeout_ms %{"relay_api" => 5_000, "relay_worker" => 30_000, "relay_queue" => 60_000}
  @min_server_version 180_000
  @wipe "TRUNCATE"
  @privileges ["SELECT", "INSERT", "UPDATE", "DELETE", @wipe]

  @doc "Runs `SELECT 1` with a short timeout."
  @spec ping() :: :ok | {:error, atom()}
  def ping do
    case Repo.query("SELECT 1", [], timeout: 1_000) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :database_unreachable}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :database_unreachable}
  end

  # TN-14
  # INV-36
  @doc "Checks the `Relay.Repo` login against the roles this node runs."
  @spec role_check() :: :ok | {:error, Relay.Error.t()}
  def role_check, do: role_check(&repo_query/2, {:app, Relay.Role.configured()})

  @doc "Checks the login behind `query` against a profile: an application node's roles, or the queue login."
  @spec role_check(query_fun(), profile()) :: :ok | {:error, Relay.Error.t()}
  def role_check(query, profile) do
    case facts(query) do
      {:ok, facts} ->
        evaluate(facts, profile)

      {:error, reason} ->
        {:error,
         Relay.Error.new(:role_check_failed, "the database role could not be checked", %{
           reason: reason
         })}
    end
  end

  @doc "Child specification that runs the role check while the supervision tree starts; a failed check stops the node."
  @spec role_check_child() :: Supervisor.child_spec()
  def role_check_child do
    %{id: :relay_role_check, start: {__MODULE__, :start_role_check, []}, restart: :temporary}
  end

  @doc "Supervisor start function of `role_check_child/0`: `:ignore` when the check passes."
  @spec start_role_check() :: :ignore | {:error, Relay.Error.t()}
  def start_role_check do
    case role_check() do
      :ok ->
        :ignore

      {:error, error} ->
        Logger.error("database role check failed; the node does not start",
          code: error.code,
          details: inspect(error.details)
        )

        {:error, error}
    end
  end

  # OP-11
  @doc "Checks that the server collects query statistics (`pg_stat_statements` in `shared_preload_libraries`). A missing module is logged as an error and reported as the `[:relay, :postgres, :query_stats]` telemetry event; the node keeps running."
  @spec query_stats_check(query_fun()) :: :ok | {:error, :query_stats_missing | String.t()}
  def query_stats_check(query \\ &repo_query/2) do
    case query.(query_stats_sql(), []) do
      {:ok, [[true]]} ->
        :ok

      {:ok, _rows} ->
        Logger.error("postgres does not collect query statistics; preload pg_stat_statements")
        :telemetry.execute([:relay, :postgres, :query_stats], %{count: 1}, %{status: :missing})
        {:error, :query_stats_missing}

      {:error, reason} ->
        Logger.warning("query statistics check could not run", reason: reason)
        {:error, reason}
    end
  end

  @doc "Child specification that runs the query statistics check once while the supervision tree starts; it never stops the node."
  @spec query_stats_check_child() :: Supervisor.child_spec()
  def query_stats_check_child do
    %{
      id: :relay_query_stats_check,
      start: {__MODULE__, :start_query_stats_check, []},
      restart: :temporary
    }
  end

  @doc "Supervisor start function of `query_stats_check_child/0`: always `:ignore`."
  @spec start_query_stats_check() :: :ignore
  def start_query_stats_check do
    _ = query_stats_check()
    :ignore
  end

  # TN-14
  # T-8
  @doc "Evaluates gathered facts against a profile; returns every violated rule."
  @spec evaluate(facts(), profile()) :: :ok | {:error, Relay.Error.t()}
  def evaluate(facts, profile) do
    case violations(facts, profile) do
      [] ->
        :ok

      found ->
        {:error,
         Relay.Error.new(
           :wrong_database_role,
           "the database login is not allowed for this node",
           %{
             login: facts.session_user,
             violations: found
           }
         )}
    end
  end

  @doc "Login roles a node with the given roles may use."
  @spec expected_logins([Relay.Role.t()]) :: [String.t()]
  def expected_logins(roles), do: roles |> Enum.map(&Map.fetch!(@logins, &1)) |> Enum.uniq()

  defp violations(facts, profile) do
    common = [
      privileged_role: Enum.any?(facts.roles, fn {_, super?, bypass?} -> super? or bypass? end),
      owns_objects: facts.owned != [],
      role_switched: facts.current_user != facts.session_user,
      wrong_login_role: facts.session_user not in logins(profile),
      unsupported_postgres: unsupported?(facts),
      row_security_off: facts.row_security != "on",
      statement_timeout:
        Map.get(@statement_timeout_ms, facts.session_user) != facts.statement_timeout_ms,
      tenant_context_preset: facts.context_settings != []
    ]

    for {violation, true} <- common ++ privileges(facts, profile), do: violation
  end

  defp privileges(facts, {:app, _roles}) do
    [
      delete_or_truncate:
        Enum.any?(facts.tables, fn {_, _, privs} -> "DELETE" in privs or @wipe in privs end),
      writes_record_tables:
        Enum.any?(facts.tables, fn {schema, _, privs} ->
          schema == "relay" and ("INSERT" in privs or "UPDATE" in privs)
        end)
    ]
  end

  defp privileges(facts, :queue) do
    [
      delete_or_truncate:
        Enum.any?(facts.tables, fn {schema, _, privs} ->
          @wipe in privs or (schema != "relay_queue" and "DELETE" in privs)
        end),
      outside_queue_schema:
        Enum.any?(facts.tables, fn {schema, _, privs} ->
          schema != "relay_queue" and privs != []
        end) or
          Enum.any?(facts.schemas, fn {schema, usage?} -> schema == "relay" and usage? end)
    ]
  end

  defp logins({:app, roles}), do: expected_logins(roles)
  defp logins(:queue), do: ["relay_queue"]

  defp unsupported?(facts) do
    facts.server_version_num < @min_server_version or
      Regex.match?(~r/(beta|rc|devel)/i, facts.server_version)
  end

  defp facts(query) do
    with {:ok, roles} <- query.(roles_sql(), []),
         {:ok, owned} <- query.(owned_sql(), []),
         {:ok, tables} <- query.(tables_sql(), [@privileges]),
         {:ok, schemas} <- query.(schemas_sql(), []),
         {:ok, [[current, session, version_num, version, row_security, timeout]]} <-
           query.(session_sql(), []),
         {:ok, settings} <- query.(settings_sql(), []) do
      {:ok,
       %{
         roles: Enum.map(roles, fn [name, super?, bypass?] -> {name, super?, bypass?} end),
         owned: List.flatten(owned),
         tables: Enum.map(tables, fn [schema, name, privs] -> {schema, name, privs} end),
         schemas: Enum.map(schemas, fn [schema, usage?] -> {schema, usage?} end),
         current_user: current,
         session_user: session,
         server_version_num: version_num,
         server_version: version,
         row_security: row_security,
         statement_timeout_ms: timeout,
         context_settings: List.flatten(settings)
       }}
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp repo_query(sql, params) do
    case Repo.query(sql, params, timeout: 5_000) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, error} -> {:error, Exception.message(error)}
    end
  rescue
    error in DBConnection.ConnectionError -> {:error, Exception.message(error)}
  end

  defp roles_sql do
    """
    SELECT r.rolname::text, r.rolsuper, r.rolbypassrls
    FROM pg_catalog.pg_roles r
    WHERE pg_catalog.pg_has_role(current_user, r.oid, 'MEMBER')
    """
  end

  defp owned_sql do
    """
    SELECT 'relation ' || c.oid::regclass::text FROM pg_catalog.pg_class c
    WHERE pg_catalog.pg_has_role(current_user, c.relowner, 'MEMBER')
    UNION ALL
    SELECT 'schema ' || n.nspname::text FROM pg_catalog.pg_namespace n
    WHERE pg_catalog.pg_has_role(current_user, n.nspowner, 'MEMBER')
    UNION ALL
    SELECT 'function ' || p.oid::regprocedure::text FROM pg_catalog.pg_proc p
    WHERE pg_catalog.pg_has_role(current_user, p.proowner, 'MEMBER')
    UNION ALL
    SELECT 'type ' || t.oid::regtype::text FROM pg_catalog.pg_type t
    WHERE pg_catalog.pg_has_role(current_user, t.typowner, 'MEMBER')
    """
  end

  defp tables_sql do
    """
    SELECT n.nspname::text, c.relname::text,
      ARRAY(SELECT p FROM unnest($1::text[]) AS p WHERE pg_catalog.has_table_privilege(c.oid, p))
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND n.nspname <> 'information_schema'
      AND n.nspname !~ '^pg_'
    """
  end

  defp schemas_sql do
    """
    SELECT n.nspname::text, pg_catalog.has_schema_privilege(n.oid, 'USAGE')
    FROM pg_catalog.pg_namespace n
    WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
    """
  end

  defp session_sql do
    """
    SELECT current_user::text, session_user::text,
      current_setting('server_version_num')::integer, current_setting('server_version'),
      current_setting('row_security'),
      (SELECT setting::integer FROM pg_catalog.pg_settings WHERE name = 'statement_timeout')
    """
  end

  defp query_stats_sql do
    """
    SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_settings WHERE name = 'pg_stat_statements.max')
    """
  end

  defp settings_sql do
    """
    SELECT DISTINCT split_part(c, '=', 1)
    FROM pg_catalog.pg_db_role_setting s, unnest(s.setconfig) AS c
    WHERE split_part(c, '=', 1) LIKE 'relay.%'
      AND (s.setdatabase = 0
           OR s.setdatabase = (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database()))
      AND (s.setrole = 0 OR pg_catalog.pg_has_role(current_user, s.setrole, 'MEMBER'))
    UNION
    SELECT v.name FROM (VALUES ('relay.tenant_id'), ('relay.environment')) AS v(name)
    WHERE coalesce(current_setting(v.name, true), '') <> ''
    """
  end
end
