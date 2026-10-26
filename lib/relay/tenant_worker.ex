defmodule Relay.TenantWorker do
  @moduledoc """
  Lazy, idle-terminating per-tenant processes. A stateful tenant component (an APNs connection, a tenant × provider breaker) is started on first use through `ensure/3` and registered under its tenant and key; a second call returns the running process.

  The worker module's `start_link/1` receives the caller's options plus `:name`, which it must register under, and `:idle_ms`, which every caller states. The worker returns that timeout from its callbacks and stops with `:normal` when it fires. Workers are temporary: one that crashes or stops is not restarted by the supervisor but started again by the next `ensure/3`, so a failing provider never spends the supervisor's restart budget. Stateless workers are shared and do not belong here.
  """

  use Supervisor

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor

  @type key :: term()

  @doc "Starts the registry and the dynamic supervisor of tenant workers."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  # T-45
  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor,
       name: @supervisor, strategy: :one_for_one, max_restarts: 3, max_seconds: 5}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 5)
  end

  # T-45
  @doc "Returns the tenant's worker for `key`, starting `module` with `opts` if none runs; `opts` must carry `:idle_ms`."
  @spec ensure(Relay.Id.t(), key(), {module(), keyword()}) :: {:ok, pid()} | {:error, term()}
  def ensure(tenant_id, key, {module, opts}) when is_atom(module) and is_list(opts) do
    idle_ms = Keyword.fetch!(opts, :idle_ms)

    unless is_integer(idle_ms) and idle_ms > 0,
      do: raise(ArgumentError, "idle_ms must be a positive integer")

    case whereis(tenant_id, key) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start(tenant_id, key, module, opts)
    end
  end

  @doc "Returns the running worker for the tenant and key, or nil."
  @spec whereis(Relay.Id.t(), key()) :: pid() | nil
  def whereis(tenant_id, key) do
    case Registry.lookup(@registry, {tenant_id, key}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp start(tenant_id, key, module, opts) do
    name = {:via, Registry, {@registry, {tenant_id, key}}}

    spec = %{
      id: {tenant_id, key},
      start: {module, :start_link, [Keyword.put(opts, :name, name)]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end
end
