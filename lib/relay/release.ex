defmodule Relay.Release do
  @moduledoc """
  Release commands run outside the serving nodes. Schema migrations are a separate step (`bin/relay eval Relay.Release.migrate`); a node never migrates on boot. After every migration the installation administrator reruns the idempotent bootstrap (`bin/relay eval Relay.Release.bootstrap`), which hands every `relay_ops` function, including one a migration dropped and created again, to `relay_maint` and grants `EXECUTE` on it only to the roles the contract lists; a node whose `relay_ops` functions have another owner refuses to start.
  """

  require Logger

  alias Ecto.Repo.Supervisor, as: RepoSupervisor
  alias Relay.Config.Env

  @attempts 3
  @backoff_ms 1_000
  @bootstrap "priv/repo/bootstrap.sql"
  @connection_keys [:hostname, :port, :database, :username, :password, :socket_dir, :ssl]

  # T-5
  # OP-57
  @doc "Runs all pending migrations for every repository; a run that hits `lock_timeout` is retried, #{@attempts} attempts in all."
  @spec migrate() :: :ok
  def migrate do
    Application.load(:relay)
    :ok = Relay.Config.SecretFiles.ensure_started()

    for repo <- Application.fetch_env!(:relay, :ecto_repos) do
      with_lock_retry(fn ->
        {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
      end)
    end

    :ok
  end

  # OP-69 (1)
  # OP-72 (2)
  # OP-73
  # T-5
  @doc "Runs `priv/repo/bootstrap.sql` as the installation administrator: the login of `ADMIN_DATABASE_URL` with the password read from `ADMIN_DATABASE_PASSWORD_FILE`. Run it before the first migration and after every migration."
  @spec bootstrap() :: :ok
  def bootstrap do
    Application.load(:relay)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    "ADMIN_DATABASE_URL"
    |> Env.database_url!()
    |> RepoSupervisor.parse_url()
    |> Keyword.put(:password, Env.file!("ADMIN_DATABASE_PASSWORD_FILE"))
    |> bootstrap()
  end

  # sobelow_skip ["Traversal.FileModule"]
  @doc "Runs the bootstrap script in one transaction over a connection opened with the given Postgrex options."
  @spec bootstrap(keyword()) :: :ok
  def bootstrap(connection) do
    {:ok, conn} = Postgrex.start_link(Keyword.take(connection, @connection_keys))

    try do
      {:ok, :ok} =
        Postgrex.transaction(conn, fn tx ->
          for statement <- statements(File.read!(bootstrap_script())),
              do: Postgrex.query!(tx, statement, [])

          :ok
        end)
    after
      GenServer.stop(conn)
    end

    :ok
  end

  @doc "Path of the bootstrap script inside the application."
  @spec bootstrap_script() :: Path.t()
  def bootstrap_script, do: Application.app_dir(:relay, @bootstrap)

  @doc "Splits a SQL script into statements, keeping dollar-quoted bodies and string literals intact."
  @spec statements(String.t()) :: [String.t()]
  def statements(sql) do
    sql
    |> split(:code, "", [])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split("", _state, current, acc), do: Enum.reverse([current | acc])
  defp split("$$" <> rest, :code, current, acc), do: split(rest, :dollar, current <> "$$", acc)
  defp split("$$" <> rest, :dollar, current, acc), do: split(rest, :code, current <> "$$", acc)
  defp split("'" <> rest, :code, current, acc), do: split(rest, :quote, current <> "'", acc)
  defp split("'" <> rest, :quote, current, acc), do: split(rest, :code, current <> "'", acc)
  defp split(";" <> rest, :code, current, acc), do: split(rest, :code, "", [current | acc])

  defp split(<<char::utf8, rest::binary>>, state, current, acc),
    do: split(rest, state, current <> <<char::utf8>>, acc)

  # OP-57
  @doc "Runs `fun`, retrying it with doubling backoff while it raises a PostgreSQL `lock_not_available` error; the last error is raised. `:attempts`, `:backoff_ms` and `:sleep` override the defaults."
  @spec with_lock_retry((-> result), keyword()) :: result when result: term()
  def with_lock_retry(fun, opts \\ []) do
    attempts = Keyword.get(opts, :attempts, @attempts)
    backoff = Keyword.get(opts, :backoff_ms, @backoff_ms)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    attempt(fun, 1, attempts, backoff, sleep)
  end

  defp attempt(fun, n, attempts, backoff, sleep) do
    fun.()
  rescue
    error in Postgrex.Error ->
      if lock_timeout?(error) and n < attempts do
        Logger.warning("migration hit lock_timeout; retrying", attempt: n, backoff_ms: backoff)
        sleep.(backoff)
        attempt(fun, n + 1, attempts, backoff * 2, sleep)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp lock_timeout?(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: true
  defp lock_timeout?(_error), do: false
end
