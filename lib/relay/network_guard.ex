defmodule Relay.NetworkGuard do
  @moduledoc """
  Guard against network calls inside a database transaction (INV-55, T-15 (6)). Every client of another service, Valkey, the key store (`Relay.Keys`) and HTTP clients, calls `check!/1` before it reaches the network. When the guard is enabled (`config :relay, Relay.NetworkGuard, enabled: true`, set in development and test) a call made while the calling process holds an open transaction on any repository raises `Relay.NetworkGuard.Error`; in production the check compiles to nothing.
  """

  defmodule Error do
    @moduledoc "Raised when a network call is made inside a database transaction."
    defexception [:target]

    @impl Exception
    def message(%{target: target}),
      do: "#{inspect(target)} called inside a database transaction (INV-55)"
  end

  @enabled Application.compile_env(:relay, [__MODULE__, :enabled], false)
  @repos [Relay.Repo, Relay.QueueRepo, Relay.Platform.MaintRepo]

  @type target :: :valkey | :keys | :http

  @dialyzer {:nowarn_function, enabled?: 0}
  @doc "Returns true when the guard raises; false in production builds."
  @spec enabled?() :: boolean()
  def enabled?, do: @enabled

  # INV-55
  # T-15 (6)
  @doc "Raises `Relay.NetworkGuard.Error` when the guard is enabled and the calling process is inside a database transaction."
  @spec check!(target()) :: :ok
  if @enabled do
    def check!(target) do
      if in_transaction?(), do: raise(Error, target: target), else: :ok
    end
  else
    def check!(_target), do: :ok
  end

  @doc "Returns true if the calling process holds an open transaction on any repository."
  @spec in_transaction?() :: boolean()
  def in_transaction?, do: Enum.any?(@repos, &repo_in_transaction?/1)

  defp repo_in_transaction?(repo) do
    GenServer.whereis(repo) != nil and repo.in_transaction?()
  end
end
