defmodule RelayDev.Database do
  @moduledoc """
  Development and test database setup. Creates the database with the local administrator login of `deploy/compose.yaml`, runs `priv/repo/bootstrap.sql` as that login through `Relay.Release.bootstrap/1`, gives the bootstrap login roles a local password, then runs the migrations as `relay_migrator` and the idempotent bootstrap once more, which hands the `relay_ops` functions to `relay_maint`. Serving nodes connect with their own login role afterwards; the administrator login is never used by the application.
  """

  alias Ecto.Adapters.Postgres

  @login_roles ~w(relay_migrator relay_api relay_worker relay_queue relay_maint relay_archive relay_report)
  @connection_keys [:hostname, :port, :database, :username, :password, :socket_dir, :ssl]
  @settings [
    admin: [username: "relay", password: "relay"],
    migrator: [username: "relay_migrator", password: "relay"],
    login_password: "relay",
    region: "tr"
  ]

  # T-5
  # OP-9
  @doc "Creates (optionally dropping first), bootstraps and migrates the configured database."
  @spec setup(keyword()) :: :ok
  def setup(opts \\ []) do
    repo_config = Application.fetch_env!(:relay, Relay.Repo)
    admin = Keyword.merge(repo_config, @settings[:admin])

    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    if Keyword.get(opts, :drop, false), do: storage_down(admin)
    storage_up(admin)
    bootstrap(admin, @settings[:login_password])

    if System.get_env("RELAY_REGION") in [nil, ""],
      do: System.put_env("RELAY_REGION", @settings[:region])

    migrate(repo_config, @settings[:migrator], Keyword.get(opts, :log, :info))
    bootstrap(admin, @settings[:login_password])
  end

  # OP-57
  @doc "Creates a separate database `name` from scratch and bootstraps it; for the nightly migration replay."
  @spec create(String.t()) :: :ok
  def create(name) do
    admin = Keyword.put(connection(:admin), :database, name)
    storage_down(admin)
    storage_up(admin)
    bootstrap(admin, @settings[:login_password])
  end

  @doc "Migrates the separate database `name` as `relay_migrator` up to version `to` (or `:all`) and runs the bootstrap again, as an upgrade of an installation does; returns the versions it applied."
  @spec upgrade(String.t(), pos_integer() | :all) :: [pos_integer()]
  def upgrade(name, to) do
    opts =
      connection("relay_migrator")
      |> Keyword.merge(database: name, pool_size: 2, name: nil)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)

    {:ok, repo} = Relay.Repo.start_link(opts)

    applied =
      try do
        target = if to == :all, do: [all: true], else: [to: to]
        Ecto.Migrator.run(Relay.Repo, :up, target ++ [dynamic_repo: repo, log: false])
      after
        Supervisor.stop(repo)
      end

    bootstrap(Keyword.put(connection(:admin), :database, name), @settings[:login_password])
    applied
  end

  @doc "Connection options for a local login role (`:admin` or a role name), taken from the repository configuration."
  @spec connection(:admin | String.t()) :: keyword()
  def connection(login) do
    credentials =
      if login == :admin,
        do: @settings[:admin],
        else: [username: login, password: @settings[:login_password]]

    :relay
    |> Application.fetch_env!(Relay.Repo)
    |> Keyword.merge(credentials)
    |> Keyword.take(@connection_keys)
  end

  defp storage_up(admin) do
    case Postgres.storage_up(admin) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> Mix.raise("could not create the database: #{inspect(reason)}")
    end
  end

  defp storage_down(admin) do
    case Postgres.storage_down(admin) do
      :ok -> :ok
      {:error, :already_down} -> :ok
      {:error, reason} -> Mix.raise("could not drop the database: #{inspect(reason)}")
    end
  end

  defp bootstrap(admin, password) do
    :ok = Relay.Release.bootstrap(admin)
    {:ok, conn} = Postgrex.start_link(Keyword.take(admin, @connection_keys))

    try do
      for role <- @login_roles do
        %{rows: [[literal]]} = Postgrex.query!(conn, "SELECT quote_literal($1::text)", [password])
        Postgrex.query!(conn, "ALTER ROLE #{role} PASSWORD #{literal}", [])
      end
    after
      GenServer.stop(conn)
    end

    :ok
  end

  defp migrate(repo_config, migrator, log) do
    Application.put_env(:relay, Relay.Repo, Keyword.merge(repo_config, migrator))

    try do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(Relay.Repo, &Ecto.Migrator.run(&1, :up, all: true, log: log))
    after
      Application.put_env(:relay, Relay.Repo, repo_config)
    end

    :ok
  end
end
