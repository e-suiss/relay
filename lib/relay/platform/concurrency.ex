defmodule Relay.Platform.Concurrency do
  @moduledoc """
  Cluster-wide concurrency limits (T-22, TN-54): in-flight delivery jobs per tenant × channel (`cc.tenant_channel:<channel>`) and per tenant (`cc.tenant_deliveries`), and provider calls per provider account (`cc.provider_account:<id>`, under the account owner's prefix). A limit per node alone is never used, because N nodes would multiply it.

  A slot is a lease held by a job (`oban:<job_id>`): 120 seconds, renewed every 40 seconds while the job runs by `Relay.Platform.Concurrency.Keeper`, released when the job ends however it ends; a crashed node's slots free themselves when their leases run out. Valkey holds the slots in a sorted set scored by lease end (`priv/valkey/concurrency.lua`), PostgreSQL in reusable rows (`relay_fn.cc_acquire`); the backend follows `Relay.Platform.Backend` with the lease as the horizon, and in `dual` a slot is taken on both backends or on neither. With no backend the limit is treated as full, never as unlimited.

  A full limit is a decision, not an error: the job snoozes for the time to the nearest lease end, clamped to 1–30 seconds, plus deterministic jitter.

  The default limits of T-91 (1), used when the tenant setting is absent: 200 in flight per tenant × channel, 1000 per tenant.
  """

  alias Relay.Platform.Backend
  alias Relay.Platform.Concurrency.Keeper
  alias Relay.Platform.Concurrency.Store
  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Key
  alias Relay.Platform.Valkey.Script

  @external_resource Script.path("concurrency")
  @script Script.read!("concurrency")

  @lease_ms 120_000
  @renew_ms 40_000
  @min_wait_ms 1_000
  @max_wait_ms 30_000
  @counter_key ~r/\Acc\.[a-z_]+(:[0-9A-Za-z_.\-]{1,128})?\z/
  @defaults %{tenant_channel: 200, tenant_deliveries: 1_000}

  @type result :: {:ok, non_neg_integer()} | {:full, non_neg_integer()}

  # T-22
  @doc "The lease of a slot in milliseconds."
  @spec lease_ms() :: pos_integer()
  def lease_ms, do: @lease_ms

  @doc "How often a held slot is renewed, in milliseconds."
  @spec renew_ms() :: pos_integer()
  def renew_ms, do: @renew_ms

  # T-91 (1)
  # TN-54
  @doc "The default limit of a counter family when the tenant has no setting."
  @spec default_limit(:tenant_channel | :tenant_deliveries) :: pos_integer()
  def default_limit(family), do: Map.fetch!(@defaults, family)

  @doc "Returns true if `key` is a valid counter key."
  @spec counter_key?(term()) :: boolean()
  def counter_key?(key), do: is_binary(key) and Regex.match?(@counter_key, key)

  # T-22
  # INV-44
  @doc """
  Takes a slot of `counter_key` for `holder`, or renews it if the holder already has one; returns `{:ok, in_use}` or `{:full, wait_ms}`. Options: `:lease_ms`, `:backend`, `:adapter`.
  """
  @spec acquire(Relay.Scope.t(), String.t(), pos_integer(), String.t(), keyword()) :: result()
  def acquire(%Relay.Scope{} = scope, counter_key, limit, holder, opts \\ [])
      when is_integer(limit) and limit > 0 do
    validate!(counter_key, holder)
    lease = Keyword.get(opts, :lease_ms, @lease_ms)
    server = Keyword.get(opts, :backend, Backend)
    adapter = Keyword.get_lazy(opts, :adapter, &Valkey.adapter/0)
    valkey = fn -> valkey_acquire(scope, counter_key, limit, holder, lease, adapter) end
    pg = fn -> pg_acquire(scope, counter_key, limit, holder, lease) end

    case Backend.current_mode(lease, server) do
      :valkey ->
        case Backend.call_valkey(valkey, server) do
          {:ok, result} -> result
          {:error, _} -> pg_or_full(pg)
        end

      :pg ->
        pg_or_full(pg)

      :dual ->
        dual(Backend.call_valkey(valkey, server), pg.(), fn
          :valkey -> valkey_release(scope, counter_key, holder, adapter)
          :pg -> Store.release(scope, counter_key, holder)
        end)
    end
  end

  defp dual({:ok, {:ok, _}}, {:ok, {:ok, n}}, _release), do: {:ok, n}

  defp dual({:ok, {:ok, _}}, {:ok, {:full, wait}}, release) do
    release.(:valkey)
    {:full, wait}
  end

  defp dual({:ok, {:full, wait}}, {:ok, {:ok, _}}, release) do
    release.(:pg)
    {:full, wait}
  end

  defp dual({:ok, {:full, a}}, {:ok, {:full, b}}, _release), do: {:full, max(a, b)}
  defp dual({:error, _}, {:ok, result}, _release), do: result
  defp dual(_valkey, _pg, _release), do: {:full, @min_wait_ms}

  defp pg_or_full(pg) do
    case pg.() do
      {:ok, result} -> result
      {:error, _} -> {:full, @min_wait_ms}
    end
  end

  # T-22
  @doc """
  Runs `fun` while holding a slot: takes it, registers it with the keeper for renewal and crash release, and releases it when `fun` returns or raises. Returns `{:ok, result}` or `{:full, wait_ms}` without running `fun`. Options as `acquire/5`, plus `:keeper`.
  """
  @spec with_slot(Relay.Scope.t(), String.t(), pos_integer(), String.t(), (-> term()), keyword()) ::
          {:ok, term()} | {:full, non_neg_integer()}
  def with_slot(%Relay.Scope{} = scope, counter_key, limit, holder, fun, opts \\ [])
      when is_function(fun, 0) do
    keeper = Keyword.get(opts, :keeper, Keeper)
    slot_opts = Keyword.delete(opts, :keeper)

    case acquire(scope, counter_key, limit, holder, slot_opts) do
      {:full, wait} ->
        {:full, wait}

      {:ok, _in_use} ->
        :ok =
          Keeper.hold(
            {scope, counter_key, limit, holder, slot_opts},
            keeper
          )

        try do
          {:ok, fun.()}
        after
          Keeper.drop(holder, keeper)
        end
    end
  end

  # T-22
  @doc "Releases `holder`'s slot on every backend that may hold it."
  @spec release(Relay.Scope.t(), String.t(), String.t(), keyword()) :: :ok
  def release(%Relay.Scope{} = scope, counter_key, holder, opts \\ []) do
    validate!(counter_key, holder)
    server = Keyword.get(opts, :backend, Backend)
    adapter = Keyword.get_lazy(opts, :adapter, &Valkey.adapter/0)
    lease = Keyword.get(opts, :lease_ms, @lease_ms)

    valkey = fn -> valkey_release(scope, counter_key, holder, adapter) end
    mode = Backend.current_mode(lease, server)
    if mode in [:valkey, :dual], do: Backend.call_valkey(valkey, server)
    if mode in [:pg, :dual], do: Store.release(scope, counter_key, holder)
    :ok
  end

  # T-22
  # T-30
  @doc "The snooze in seconds for a full limit: the wait clamped to 1–30 seconds plus the deterministic `snooze` jitter of the job and its `k`-th snooze."
  @spec snooze_seconds(Relay.Scope.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          pos_integer()
  def snooze_seconds(%Relay.Scope{} = scope, job_ref, k, wait_ms) do
    base = wait_ms |> max(@min_wait_ms) |> min(@max_wait_ms)

    ms = Relay.Jitter.snooze(scope.tenant_id, scope.environment, job_ref, k, base)

    div(ms + 999, 1000)
  end

  defp validate!(counter_key, holder) do
    unless counter_key?(counter_key), do: raise(ArgumentError, "invalid counter key")

    unless is_binary(holder) and byte_size(holder) in 1..128,
      do: raise(ArgumentError, "invalid holder")
  end

  defp pg_acquire(scope, counter_key, limit, holder, lease) do
    case Store.acquire(scope, counter_key, limit, holder, lease) do
      {:ok, {:full, _in_use, wait}} -> {:ok, {:full, wait}}
      {:ok, {_granted, in_use, _wait}} -> {:ok, {:ok, in_use}}
      {:error, _} = error -> error
    end
  end

  defp valkey_acquire(scope, counter_key, limit, holder, lease, adapter) do
    with {:ok, key} <- key(scope, counter_key),
         {:ok, [code, n, wait]} <-
           Valkey.eval(@script, key, ["acquire", holder, limit, lease], adapter) do
      {:ok, if(code == 1, do: {:ok, n}, else: {:full, max(0, wait)})}
    else
      {:error, _} = error -> error
      _ -> {:error, Relay.Error.new(:valkey_reply, "unexpected concurrency reply")}
    end
  end

  defp valkey_release(scope, counter_key, holder, adapter) do
    with {:ok, key} <- key(scope, counter_key),
         {:ok, [_code, _n, _]} <-
           Valkey.eval(@script, key, ["release", holder, 1, @lease_ms], adapter) do
      {:ok, :released}
    else
      {:error, _} = error -> error
      _ -> {:error, Relay.Error.new(:valkey_reply, "unexpected concurrency reply")}
    end
  end

  defp key(%Relay.Scope{tenant_id: tenant_id, environment: environment}, counter_key) do
    Key.new(
      Relay.Id.to_string(tenant_id),
      Relay.Environment.dump(environment),
      ["cc" | String.split(counter_key, ":")],
      @lease_ms
    )
  end
end
