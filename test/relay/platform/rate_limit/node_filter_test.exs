defmodule Relay.Platform.RateLimit.NodeFilterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Platform.RateLimit.Gcra
  alias Relay.Platform.RateLimit.Limit
  alias Relay.Platform.RateLimit.NodeFilter

  defmodule SimClock do
    @moduledoc false
    def monotonic_ms, do: Process.get(:sim_ms, 0)
  end

  defp limit(limit, period_ms, burst, algorithm \\ :gcra) do
    Limit.new!(
      id: "api.burst",
      algorithm: algorithm,
      unit: :request,
      limit: limit,
      period_ms: period_ms,
      burst: burst
    )
  end

  defp table, do: :ets.new(:node_filter_test, [:set, :public])

  defp opts(table), do: [table: table, clock: SimClock]

  defp at(ms), do: Process.put(:sim_ms, ms)

  defp scope, do: Relay.Scope.new!(Relay.Id.generate(), :live)

  describe "T-94 T-42 node-local first pass" do
    test "T-94: the filter passes until this node's allowed consumption reaches the burst" do
      table = table()
      scope = scope()
      limit = limit(2, 1_000, 2)
      at(10_000)

      assert NodeFilter.check(scope, limit, ["all"], 1, opts(table)) == :pass
      :ok = NodeFilter.note(scope, limit, ["all"], 1, opts(table))
      assert NodeFilter.check(scope, limit, ["all"], 1, opts(table)) == :pass
      :ok = NodeFilter.note(scope, limit, ["all"], 1, opts(table))

      assert NodeFilter.check(scope, limit, ["all"], 1, opts(table)) == {:deny, 500}
      assert NodeFilter.check(scope(), limit, ["all"], 1, opts(table)) == :pass
      assert NodeFilter.check(scope, limit, ["other"], 1, opts(table)) == :pass
    end

    test "T-94: time is the monotonic clock port; elapsed time frees capacity" do
      table = table()
      scope = scope()
      limit = limit(2, 1_000, 2)
      at(5_000)

      :ok = NodeFilter.note(scope, limit, ["all"], 2, opts(table))
      assert {:deny, _retry} = NodeFilter.check(scope, limit, ["all"], 1, opts(table))

      at(5_499)
      assert {:deny, 1} = NodeFilter.check(scope, limit, ["all"], 1, opts(table))

      at(5_500)
      assert NodeFilter.check(scope, limit, ["all"], 1, opts(table)) == :pass
    end

    test "T-94: only GCRA limits are filtered; a cost beyond the burst is left to the cluster" do
      table = table()
      scope = scope()
      at(0)

      window = limit(10, 60_000, nil, :sliding_counter)
      :ok = NodeFilter.note(scope, window, ["all"], 10, opts(table))
      assert NodeFilter.check(scope, window, ["all"], 10, opts(table)) == :pass
      assert :ets.info(table, :size) == 0

      assert NodeFilter.check(scope, limit(2, 1_000, 2), ["all"], 3, opts(table)) == :pass
    end

    test "T-94: without its table the filter passes everything to the cluster limiter" do
      at(0)
      limit = limit(1, 1_000, 1)
      opts = [table: :node_filter_absent, clock: SimClock]

      :ok = NodeFilter.note(scope(), limit, ["all"], 1, opts)
      assert NodeFilter.check(scope(), limit, ["all"], 1, opts) == :pass
    end

    test "T-94: the sweep drops only entries whose arrival time has passed" do
      table = table()
      scope = scope()
      limit = limit(1, 1_000, 1)
      at(0)

      :ok = NodeFilter.note(scope, limit, ["old"], 1, opts(table))
      at(900)
      :ok = NodeFilter.note(scope, limit, ["new"], 1, opts(table))

      assert NodeFilter.sweep(table, 1_000_000) == 1
      assert {:deny, _retry} = NodeFilter.check(scope, limit, ["new"], 1, opts(table))
    end

    property "T-94: a node-local refusal is always a refusal of the cluster limiter" do
      step = tuple({integer(0..2), integer(0..400), integer(1..3)})

      check all steps <- list_of(step, max_length: 60) do
        limit = limit(5, 1_000, 5)
        scope = scope()
        tables = Map.new(0..2, &{&1, table()})

        params = %{
          emission_us: Gcra.emission_us(5, 1_000),
          burst: 5,
          cap: -1,
          limit: 5,
          period_us: 1_000_000,
          offset_us: 0
        }

        Enum.reduce(steps, {nil, 1_000}, fn {node, dt, cost}, {cluster, now} ->
          now = now + dt
          at(now)
          node_opts = opts(tables[node])
          decided = Gcra.step(cluster, Map.put(params, :cost, cost), now * 1000)

          case NodeFilter.check(scope, limit, ["all"], cost, node_opts) do
            {:deny, _retry} ->
              assert elem(decided, 0) == :limited
              {cluster, now}

            :pass ->
              case decided do
                {:allowed, _outcome, state} ->
                  :ok = NodeFilter.note(scope, limit, ["all"], cost, node_opts)
                  {state, now}

                {_denied, _outcome, state} ->
                  {state, now}
              end
          end
        end)
      end
    end
  end
end
