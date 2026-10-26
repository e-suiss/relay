defmodule Relay.Platform.RateLimit.MatrixTest do
  use ExUnit.Case, async: false

  import Relay.SqlCase, only: [connect: 1, rolled_back: 2, rows: 2, tenant!: 0, ctx: 1]

  alias Relay.Platform.RateLimit.Limit
  alias Relay.Platform.RateLimit.Ring
  alias Relay.Platform.RateLimit.Scripts
  alias Relay.Platform.RateLimit.Window
  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Script

  @vectors "test/vectors/rate_limit/window_v1.json" |> File.read!() |> Jason.decode!()
  @t0 @vectors["t0_us"]
  @algorithms %{
    "fixed_window" => :fixed_window,
    "sliding_counter" => :sliding_counter,
    "sliding_log" => :sliding_log
  }
  @tags %{"fixed_window" => "f", "sliding_counter" => "s", "sliding_log" => "l"}

  defp limit(attrs) do
    Map.merge(
      %{id: "quota.test", unit: :message, limit: 10, period_ms: 3_600_000},
      Map.new(attrs)
    )
  end

  defp await_valkey(0), do: flunk("Valkey is not reachable")

  defp await_valkey(n) do
    if Valkey.ping() == :ok,
      do: :ok,
      else:
        (
          Process.sleep(50)
          await_valkey(n - 1)
        )
  end

  defp seed_w(vector) do
    first = hd(vector["steps"])["t"]
    window_us = vector["window_ms"] * 1000

    Integer.floor_div(@t0 + first + vector["offset_ms"] * 1000, window_us) +
      vector["seed"]["w_rel"]
  end

  defp run(vector, decide) do
    for step <- vector["steps"] do
      p = %{
        limit: vector["limit"],
        window_ms: vector["window_ms"],
        offset_ms: vector["offset_ms"],
        cost: step["cost"]
      }

      label = "#{vector["id"]} at #{step["t"]}"

      assert decide.(p, @t0 + step["t"]) ==
               {step["expect"], step["count_after"], step["retry_after_ms"]},
             label
    end
  end

  describe "T-19 algorithm matrix" do
    test "T-19: a fixed window shorter than an hour is refused, so a one-second provider limit cannot use it" do
      assert {:error, %Relay.Error{code: :invalid_limit}} =
               Limit.new(limit(algorithm: :fixed_window, period_ms: 1_000))

      assert {:ok, _} = Limit.new(limit(algorithm: :fixed_window, period_ms: 3_600_000))
    end

    test "T-19: a sliding log holds at most 1000 and only GCRA has a burst or a lane ceiling" do
      assert {:error, _} = Limit.new(limit(algorithm: :sliding_log, limit: 1001))
      assert {:ok, _} = Limit.new(limit(algorithm: :sliding_log, limit: 1000))
      assert {:error, _} = Limit.new(limit(algorithm: :sliding_counter, burst: 3))
      assert {:error, _} = Limit.new(limit(algorithm: :sliding_counter, ceiling: true))
      assert {:error, _} = Limit.new(limit(algorithm: :gcra, period_ms: 1_000))

      assert {:ok, _} =
               Limit.new(limit(algorithm: :gcra, period_ms: 1_000, burst: 1, ceiling: true))
    end

    test "T-19: the counting unit is one of the channel units and the id is a dotted name" do
      assert {:error, _} = Limit.new(limit(algorithm: :gcra, burst: 1, unit: :byte))
      assert {:error, _} = Limit.new(limit(algorithm: :gcra, burst: 1, id: "Bad id"))

      for unit <- [:message, :recipient, :segment, :unique_recipient, :request],
          do: assert({:ok, _} = Limit.new(limit(algorithm: :gcra, burst: 1, unit: unit)))
    end

    test "T-19: the sliding counter allows only 90 % of its limit" do
      assert Window.effective_limit(100) == 90
      assert Window.effective_limit(7) == 6
    end

    test "T-19: the window offset follows the key, with the published vector" do
      for v <- @vectors["offset_vectors"] do
        assert Relay.Jitter.digest_input("window_offset", [v["limit_key"]])
               |> Base.encode16(case: :lower) == v["cbor"]

        assert Relay.Jitter.h("window_offset", [v["limit_key"]]) == String.to_integer(v["h"])
        assert Relay.Jitter.window_offset(v["limit_key"], v["window_ms"]) == v["offset_ms"]
      end

      offsets =
        for i <- 1..50,
            uniq: true,
            do: Relay.Jitter.window_offset("quota.hourly:a#{i}", 3_600_000)

      assert length(offsets) > 40
    end

    test "T-19: S1, S2, F1 and K1 hold on the pure cores" do
      for vector <- @vectors["vectors"] do
        algorithm = Map.fetch!(@algorithms, vector["algorithm"])
        seed = vector["seed"]
        initial = if seed, do: %{w: seed_w(vector), c: seed["c"], p: seed["p"]}, else: nil
        {:ok, state} = Agent.start_link(fn -> initial end)

        run(vector, fn p, now ->
          {{code, count, retry}, next} = Window.step(algorithm, Agent.get(state, & &1), p, now)
          Agent.update(state, fn _ -> next end)
          {Atom.to_string(code), count, retry}
        end)
      end
    end

    test "T-27: the limitless counter and TN-43: the bucket ring hold on the pure cores" do
      for v <- @vectors["counter_vectors"] do
        Enum.reduce(v["steps"], nil, fn s, state ->
          {estimate, next} =
            Window.counter(
              String.to_existing_atom(s["op"]),
              state,
              v["window_ms"],
              s["by"],
              @t0 + s["t"]
            )

          assert estimate == s["estimate"], "#{v["id"]} at #{s["t"]}"
          next
        end)
      end

      for v <- @vectors["ring_vectors"] do
        Enum.reduce(v["steps"], nil, fn s, state ->
          {{current, baseline}, next} =
            Ring.step(state, s["cost"], v["current_minutes"], v["baseline_minutes"], @t0 + s["t"])

          assert {current, baseline} == {s["current_sum"], s["baseline_sum"]},
                 "#{v["id"]} at #{s["t"]}"

          next
        end)
      end
    end
  end

  describe "T-9 (4) window vectors on Valkey" do
    @describetag :integration

    setup do
      await_valkey(100)
    end

    test "T-19: window.lua and rate_ring.lua give the vector results" do
      window = Script.new("window_at", File.read!("test/support/valkey/window_at.lua"))
      ring = Script.new("rate_ring_at", File.read!("test/support/valkey/rate_ring_at.lua"))
      scope = fn -> Relay.Scope.new!(Relay.Id.generate(), :test) end

      for vector <- @vectors["vectors"] do
        tag = Map.fetch!(@tags, vector["algorithm"])
        {:ok, key} = Scripts.key(scope.(), ["rl", tag], "vec.window:" <> vector["id"])

        if seed = vector["seed"] do
          {:ok, _} =
            Valkey.adapter().command(
              ["HSET", key.name, "w", seed_w(vector), "c", seed["c"], "p", seed["p"]]
              |> Enum.map(&to_string/1)
            )

          {:ok, 1} = Valkey.adapter().command(["PEXPIRE", key.name, "600000"])
        end

        run(vector, fn p, now ->
          args = ["check", tag, p.limit, p.window_ms, p.offset_ms, p.cost, now]
          {:ok, [code, count, retry]} = Valkey.eval(window, key, args)
          {Enum.at(~w(allowed limited), code), count, retry}
        end)
      end

      for v <- @vectors["counter_vectors"] do
        {:ok, key} = Scripts.key(scope.(), ["rl", "s"], "vec.counter:" <> v["id"])

        for s <- v["steps"] do
          {:ok, [0, estimate, 0]} =
            Valkey.eval(window, key, [s["op"], "s", 1, v["window_ms"], 0, s["by"], @t0 + s["t"]])

          assert estimate == s["estimate"], "#{v["id"]} at #{s["t"]}"
        end
      end

      for v <- @vectors["ring_vectors"] do
        {:ok, key} = Scripts.key(scope.(), [], "dms:tenant:" <> v["id"])

        for s <- v["steps"] do
          args = [s["cost"], v["current_minutes"], v["baseline_minutes"], @t0 + s["t"]]
          assert {:ok, [s["current_sum"], s["baseline_sum"]]} == Valkey.eval(ring, key, args)
        end
      end
    end
  end

  describe "T-9 (4) window vectors on PostgreSQL" do
    @describetag :integration

    test "T-19: rl_window_at, rl_counter_at and rl_ring_at give the vector results" do
      conn = connect(:admin)

      rolled_back(conn, fn ->
        tenant = tenant!()
        rows("SET LOCAL ROLE relay_owner", [])
        "active" = ctx(tenant)

        for vector <- @vectors["vectors"] do
          key = "vec.window:" <> vector["id"]

          if seed = vector["seed"] do
            rows(
              """
              INSERT INTO relay_queue.limiter_states (tenant_id, environment, limit_key, algorithm,
                win_index, cur_count, prev_count, expires_at, updated_at)
              VALUES ($1, 'test', $2, $3, $4, $5, $6, now() + interval '1 hour', now())
              """,
              [tenant, key, vector["algorithm"], seed_w(vector), seed["c"], seed["p"]]
            )
          end

          run(vector, fn p, now ->
            [[code, count, retry]] =
              rows("SELECT * FROM relay_private.rl_window_at($1, $2, $3, $4, $5, $6, $7)", [
                now,
                key,
                vector["algorithm"],
                p.limit,
                p.window_ms,
                p.offset_ms,
                p.cost
              ])

            {code, count, retry}
          end)
        end

        for v <- @vectors["counter_vectors"], s <- v["steps"] do
          assert rows("SELECT * FROM relay_private.rl_counter_at($1, $2, $3, $4, $5)", [
                   @t0 + s["t"],
                   "vec.counter:" <> v["id"],
                   v["window_ms"],
                   s["op"],
                   s["by"]
                 ]) == [[s["estimate"]]],
                 "#{v["id"]} at #{s["t"]}"
        end

        for v <- @vectors["ring_vectors"], s <- v["steps"] do
          assert rows("SELECT * FROM relay_private.rl_ring_at($1, $2, $3, $4, $5)", [
                   @t0 + s["t"],
                   "dms:tenant:" <> v["id"],
                   s["cost"],
                   v["current_minutes"],
                   v["baseline_minutes"]
                 ]) == [[s["current_sum"], s["baseline_sum"]]],
                 "#{v["id"]} at #{s["t"]}"
        end
      end)

      GenServer.stop(conn)
    end
  end
end
