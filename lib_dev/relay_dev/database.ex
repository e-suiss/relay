defmodule RelayDev.Database do
  @moduledoc """
  Development and test database setup. Creates the database with the local administrator login of `deploy/compose.yaml`, runs `priv/repo/bootstrap.sql` as that login, gives the bootstrap login roles a local password, then runs the migrations as `relay_migrator`. Serving nodes connect with their own login role afterwards; the administrator login is never used by the application.
  """

  alias Ecto.Adapters.Postgres

  @bootstrap "priv/repo/bootstrap.sql"
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
    {:ok, conn} = Postgrex.start_link(Keyword.take(admin, @connection_keys))

    try do
      for statement <- statements(File.read!(@bootstrap)),
          do: Postgrex.query!(conn, statement, [])

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
