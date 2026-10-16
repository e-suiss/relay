defmodule Relay.Release do
  @moduledoc """
  Release commands run outside the serving nodes. Schema migrations are a separate step (`bin/relay eval Relay.Release.migrate`); a node never migrates on boot.
  """

  require Logger

  @attempts 3
  @backoff_ms 1_000

  # T-5
  # OP-57
  @doc "Runs all pending migrations for every repository; a run that hits `lock_timeout` is retried, #{@attempts} attempts in all."
  @spec migrate() :: :ok
  def migrate do
    Application.load(:relay)

    for repo <- Application.fetch_env!(:relay, :ecto_repos) do
      with_lock_retry(fn ->
        {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
      end)
    end

    :ok
  end

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
