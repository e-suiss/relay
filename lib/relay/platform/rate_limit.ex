defmodule Relay.Platform.RateLimit do
  @moduledoc """
  Relay's cluster-wide rate limiter (T-18, T-19, T-20). Valkey is the primary backend, one atomic script per decision; PostgreSQL is the fallback, one `INSERT … ON CONFLICT DO UPDATE … WHERE … RETURNING` per decision, where an empty `RETURNING` is a denial. The backend comes from `Relay.Platform.Backend`:

  * `valkey`: the script decides; a failed call falls through to PostgreSQL for the same request and moves the node to `pg`.
  * `pg`: PostgreSQL decides.
  * `dual`, until a key's horizon has passed after Valkey returns: both backends decide and consume, the request passes only if both allow, and `retry_after` is the larger one.

  There is no unlimited branch (INV-44): when no backend answers, the decision is a denial with `retry_after = 1 s` and rule `rate_limit.backend_unavailable`. Time is the deciding backend's clock (T-11), never the node's. A denial is a decision, not an error; the job snoozes for `ceil(retry_after_ms / 1000)` seconds. A provider's `Retry-After` is applied by the retry policy with up to 20 % deterministic jitter (`Relay.Jitter.retry_after/5`, T-20 (3)), and Relay's own limits are set stricter than the provider's published ones (T-20 (4)).

  A shared provider account's counters carry the prefix of the tenant that owns the account (the installation tenant for SaaS accounts); the caller passes that owner's scope.
  """

  alias Relay.Platform.Backend
  alias Relay.Platform.RateLimit.CreditLease
  alias Relay.Platform.RateLimit.Gcra
  alias Relay.Platform.RateLimit.Limit
  alias Relay.Platform.RateLimit.Scripts
  alias Relay.Platform.RateLimit.Store
  alias Relay.Platform.Valkey

  @lanes [:l0, :l1, :l2, :l3]
  @limit_key ~r/\A[a-z][a-z0-9_.]{2,63}(:[0-9A-Za-z_.\-]{1,128}){1,6}\z/
  @ring_horizon_ms 7_200_000

  @type lane :: :l0 | :l1 | :l2 | :l3
  @type decision :: {:allow, map()} | {:deny, pos_integer(), String.t()}
  @type option ::
          {:ceiling_bp, 1..10_000}
          | {:lease, CreditLease.lease()}
          | {:backend, GenServer.name()}
          | {:adapter, module()}

  # T-19
  # T-20
  # T-33
  # INV-44
  # CH-17
  @doc """
  Decides one request of `cost` units on `limit` for the key built from `key_parts` in `scope`, on `lane`.

  Options: `:ceiling_bp`, the lane's ceiling in basis points, required for a limit with `ceiling: true` (T-33; `l0` is held only by the GCRA itself); `:lease`, the channel's credit lease `{allowed, block_size}` (T-20 (5), default no lease); `:backend` and `:adapter` select the backend server and the Valkey adapter. A key without parts raises: there is no keyless limiter.
  """
  @spec check(Relay.Scope.t(), Limit.t(), [String.t()], pos_integer(), lane(), [option()]) ::
          decision()
  def check(%Relay.Scope{} = scope, %Limit{} = limit, key_parts, cost, lane, opts \\ [])
      when is_integer(cost) and cost > 0 and lane in @lanes do
    limit_key =
      case Limit.key(limit, key_parts) do
        {:ok, key} -> key
        {:error, error} -> raise ArgumentError, error.message
      end

    decision =
      case limit.algorithm do
        :gcra -> gcra(scope, limit, limit_key, cost, lane, opts)
        algorithm -> window(scope, limit, limit_key, algorithm, cost, opts)
      end

    :telemetry.execute([:relay, :rate_limit, :decision], %{count: 1}, %{
      limit_id: limit.id,
      lane: lane,
      result: elem(decision, 0)
    })

    decision
  end

  defp gcra(scope, limit, limit_key, cost, lane, opts) do
    emission = Gcra.emission_us(limit.limit, limit.period_ms)

    params = %{
      emission_us: emission,
      burst: limit.burst,
      cost: cost,
      cap: cap(limit, lane, opts),
      limit: limit.limit,
      period_us: limit.period_ms * 1000,
      offset_us:
        if(limit.ceiling,
          do: Relay.Jitter.window_offset(limit_key, limit.period_ms) * 1000,
          else: 0
        )
    }

    central = fn cost ->
      gcra_central(scope, limit, limit_key, %{params | cost: cost}, lane, opts)
    end

    case CreditLease.block_size(Keyword.get(opts, :lease, {false, nil}), limit.burst) do
      nil ->
        central.(cost)

      block ->
        lease_key = {scope.tenant_id, scope.environment, limit_key, lane}
        valid_ms = Gcra.ceil_div(block * emission, 1000)

        lease = fn -> lease_reply(central.(block), valid_ms) end

        case CreditLease.spend(lease_key, cost, block, lease) do
          :allowed -> {:allow, %{backend: :lease}}
          :central -> central.(cost)
        end
    end
  end

  defp lease_reply({:allow, _meta}, valid_ms), do: {:allow, valid_ms}
  defp lease_reply({:deny, _retry, _rule}, _valid_ms), do: :deny

  defp gcra_central(scope, limit, limit_key, params, lane, opts) do
    adapter = adapter(opts)

    decide(
      Limit.horizon_ms(limit),
      fn -> Scripts.gcra(scope, limit_key, params, adapter) end,
      fn -> Store.gcra(scope, limit_key, params) end,
      &gcra_decision(&1, limit, lane),
      opts
    )
  end

  defp gcra_decision({:allowed, _retry}, _limit, _lane), do: :allow
  defp gcra_decision({:limited, retry_us}, limit, _lane), do: {:deny, ms(retry_us), rule(limit)}

  defp gcra_decision({:ceiling, retry_us}, _limit, lane),
    do: {:deny, ms(retry_us), "rate_limit.lane_ceiling.#{lane}"}

  defp gcra_decision({:cost_exceeds_burst, _retry}, limit, _lane),
    do: {:deny, limit.period_ms, "rate_limit.cost_exceeds_burst"}

  defp window(scope, limit, limit_key, algorithm, cost, opts) do
    adapter = adapter(opts)

    params = %{
      limit: limit.limit,
      window_ms: limit.period_ms,
      offset_ms:
        if(algorithm == :sliding_log,
          do: 0,
          else: Relay.Jitter.window_offset(limit_key, limit.period_ms)
        ),
      cost: cost
    }

    decide(
      Limit.horizon_ms(limit),
      fn -> Scripts.window(scope, limit_key, algorithm, params, adapter) end,
      fn -> Store.window(scope, limit_key, algorithm, params) end,
      fn
        {:allowed, _count, _retry} -> :allow
        {:limited, _count, retry_ms} -> {:deny, max(1, retry_ms), rule(limit)}
      end,
      opts
    )
  end

  # T-33
  defp cap(%Limit{ceiling: false}, _lane, _opts), do: -1
  defp cap(%Limit{}, :l0, _opts), do: -1

  defp cap(%Limit{limit: l}, _lane, opts) do
    case Keyword.fetch(opts, :ceiling_bp) do
      {:ok, bp} when is_integer(bp) and bp in 1..10_000 -> div(l * bp, 10_000)
      _ -> raise ArgumentError, "a ceiling limit needs the lane's ceiling_bp"
    end
  end

  # T-9 (3)
  # T-9 (5)
  # INV-44
  defp decide(horizon_ms, valkey, pg, to_decision, opts) do
    server = Keyword.get(opts, :backend, Backend)

    horizon_ms
    |> Backend.current_mode(server)
    |> run_mode(server, valkey, pg, to_decision)
    |> to_result()
  end

  defp run_mode(:valkey, server, valkey, pg, to_decision) do
    case Backend.call_valkey(valkey, server) do
      {:ok, reply} -> {:valkey, to_decision.(reply)}
      {:error, _} -> pg_only(pg, to_decision)
    end
  end

  defp run_mode(:pg, _server, _valkey, pg, to_decision), do: pg_only(pg, to_decision)

  defp run_mode(:dual, server, valkey, pg, to_decision) do
    case {Backend.call_valkey(valkey, server), pg.()} do
      {{:ok, a}, {:ok, b}} -> {:dual, stricter(to_decision.(a), to_decision.(b))}
      {{:error, _}, {:ok, b}} -> {:pg, to_decision.(b)}
      _ -> :unavailable
    end
  end

  defp to_result({backend, :allow}), do: {:allow, %{backend: backend}}
  defp to_result({_backend, {:deny, _retry, _rule} = deny}), do: deny

  defp to_result(:unavailable) do
    %{retry_after_ms: retry, rule_id: rule} = Backend.deny_reason()
    {:deny, retry, rule}
  end

  defp pg_only(pg, to_decision) do
    case pg.() do
      {:ok, reply} -> {:pg, to_decision.(reply)}
      {:error, _} -> :unavailable
    end
  end

  # T-9 (5)
  @doc "Combines two backends' decisions: allowed only if both allow; otherwise the denial with the longer wait."
  @spec stricter(
          :allow | {:deny, pos_integer(), String.t()},
          :allow | {:deny, pos_integer(), String.t()}
        ) ::
          :allow | {:deny, pos_integer(), String.t()}
  def stricter(:allow, :allow), do: :allow
  def stricter(:allow, deny), do: deny
  def stricter(deny, :allow), do: deny
  def stricter({:deny, a, _} = x, {:deny, b, _} = y), do: if(a >= b, do: x, else: y)

  # T-27
  @doc """
  Adds `by` to (`:incr`) or reads (`:read`) a sliding counter of `window_ms` without a limit, as the retry budget needs; returns the estimate. In `dual` both backends count and the larger estimate wins. When no backend answers it returns an error and the caller must treat it as a denial.
  """
  @spec counter(Relay.Scope.t(), String.t(), pos_integer(), :incr | :read, non_neg_integer(), [
          option()
        ]) ::
          {:ok, non_neg_integer()} | {:error, Relay.Error.t()}
  def counter(%Relay.Scope{} = scope, limit_key, window_ms, op, by, opts \\ [])
      when op in [:incr, :read] and is_integer(window_ms) and window_ms > 0 and is_integer(by) and
             by >= 0 do
    key!(limit_key)
    adapter = adapter(opts)

    measure(
      2 * window_ms,
      fn -> Scripts.counter(scope, limit_key, window_ms, op, by, adapter) end,
      fn -> Store.counter(scope, limit_key, window_ms, op, by) end,
      &max/2,
      opts
    )
  end

  # TN-43
  @doc """
  Adds `cost` to the current minute of a 120-minute bucket ring and returns `{current_sum, baseline_sum}`: the last `current` minutes and the `baseline` minutes before them. In `dual` both backends count and each sum is the larger one; with no backend it returns an error.
  """
  @spec ring(Relay.Scope.t(), String.t(), non_neg_integer(), pos_integer(), non_neg_integer(), [
          option()
        ]) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, Relay.Error.t()}
  def ring(%Relay.Scope{} = scope, limit_key, cost, current, baseline, opts \\ [])
      when is_integer(cost) and cost >= 0 and is_integer(current) and current >= 1 and
             is_integer(baseline) and baseline >= 0 and current + baseline <= 120 do
    key!(limit_key)
    adapter = adapter(opts)

    measure(
      @ring_horizon_ms,
      fn -> Scripts.ring(scope, limit_key, cost, current, baseline, adapter) end,
      fn -> Store.ring(scope, limit_key, cost, current, baseline) end,
      fn {a1, b1}, {a2, b2} -> {max(a1, a2), max(b1, b2)} end,
      opts
    )
  end

  defp measure(horizon_ms, valkey, pg, merge, opts) do
    server = Keyword.get(opts, :backend, Backend)

    case Backend.current_mode(horizon_ms, server) do
      :valkey ->
        case Backend.call_valkey(valkey, server) do
          {:ok, _} = ok -> ok
          {:error, _} -> pg_measure(pg)
        end

      :pg ->
        pg_measure(pg)

      :dual ->
        case {Backend.call_valkey(valkey, server), pg.()} do
          {{:ok, a}, {:ok, b}} -> {:ok, merge.(a, b)}
          {{:error, _}, {:ok, _} = ok} -> ok
          _ -> unavailable()
        end
    end
  end

  defp pg_measure(pg) do
    case pg.() do
      {:ok, _} = ok -> ok
      {:error, _} -> unavailable()
    end
  end

  defp unavailable do
    %{rule_id: rule} = Backend.deny_reason()

    {:error,
     Relay.Error.new(:limiter_unavailable, "no limiter backend answered", %{rule_id: rule})}
  end

  defp key!(limit_key) do
    unless is_binary(limit_key) and Regex.match?(@limit_key, limit_key),
      do: raise(ArgumentError, "invalid limit key")
  end

  defp adapter(opts), do: Keyword.get_lazy(opts, :adapter, &Valkey.adapter/0)
  defp rule(%Limit{id: id}), do: "rate_limit." <> id
  defp ms(us), do: max(1, Gcra.ceil_div(us, 1000))
end
