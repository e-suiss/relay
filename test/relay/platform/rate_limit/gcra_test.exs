defmodule Relay.Platform.RateLimit.GcraTest do
  use ExUnit.Case, async: false

  import Relay.SqlCase, only: [connect: 1, rolled_back: 2, rows: 2, tenant!: 0, ctx: 1]

  alias Relay.Platform.RateLimit.Gcra
  alias Relay.Platform.RateLimit.Scripts
  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Script

  @vectors "test/vectors/rate_limit/gcra_v1.json" |> File.read!() |> Jason.decode!()
  @t0 @vectors["t0_us"]
  @ceiling @vectors["ceiling_bp"]

  defp params(vector, cost, lane) do
    %{"L" => l, "P_ms" => p, "B" => b, "ceiling" => ceiling, "offset_us" => off} =
      vector["limit"]

    cap =
      if ceiling and lane != "l0",
        do: div(l * Map.fetch!(@ceiling, lane), 10_000),
        else: -1

    %{
      emission_us: Gcra.emission_us(l, p),
      burst: b,
      cost: cost,
      cap: cap,
      limit: l,
      period_us: p * 1000,
      offset_us: off
    }
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

  defp steps(vector) do
    for step <- vector["steps"],
        i <- 0..(Map.get(step, "repeat", 1) - 1)//1,
        do: {step, step["t"] + i * Map.get(step, "every", 0)}
  end

  defp run(vector, decide) do
    for {step, t} <- steps(vector) do
      {code, retry, tat} =
        decide.(params(vector, step["cost"], Map.get(step, "lane", "l0")), @t0 + t)

      label = "#{vector["id"]} at #{t}"
      assert code == step["expect"], label
      if step["retry_after_us"], do: assert(retry == step["retry_after_us"], label)
      if step["tat"], do: assert(tat - @t0 == step["tat"], label)
    end
  end

  defp pure(vector) do
    {:ok, state} = Agent.start_link(fn -> nil end)

    run(vector, fn p, now ->
      {code, out, next} = Gcra.step(Agent.get(state, & &1), p, now)
      Agent.update(state, fn _ -> next end)
      {Atom.to_string(code), out.retry_after_us, out.tat_us}
    end)

    Agent.get(state, & &1)
  end

  describe "T-20 T-11 T-33 the pure GCRA core" do
    test "T-20: G1–G9 hold on the pure core" do
      for vector <- @vectors["vectors"], do: pure(vector)
    end

    test "T-19: the emission interval is rounded up, so Relay is stricter than the provider" do
      assert Gcra.emission_us(3, 1000) == 333_334
      assert Gcra.emission_us(7, 1000) == 142_858
      assert Gcra.emission_us(10, 1000) == 100_000
    end

    test "T-20: G5 a cost above the burst never passes and leaves no state" do
      vector = Enum.find(@vectors["vectors"], &(&1["id"] == "G5"))
      assert pure(vector) == nil
    end

    test "T-11: G6 a clock that steps back cannot release capacity" do
      p = %{
        emission_us: 100_000,
        burst: 1,
        cost: 1,
        cap: -1,
        limit: 10,
        period_us: 1_000_000,
        offset_us: 0
      }

      {:allowed, _, state} = Gcra.step(nil, p, @t0)

      for back <- [1, 500_000, 10_000_000] do
        assert {:limited, %{retry_after_us: retry}, ^state} = Gcra.step(state, p, @t0 - back)
        assert retry == 100_000 + back
      end
    end

    test "T-18: fractional refill is never lost over a long run" do
      p = %{
        emission_us: 142_858,
        burst: 1,
        cost: 1,
        cap: -1,
        limit: 7,
        period_us: 1_000_000,
        offset_us: 0
      }

      {codes, _} =
        Enum.map_reduce(0..6_999, nil, fn i, state ->
          {code, _, next} = Gcra.step(state, p, @t0 + i * 142_858)
          {code, next}
        end)

      assert Enum.all?(codes, &(&1 == :allowed))
    end

    test "T-18: retry_after is exact: waiting it out passes and one microsecond less does not" do
      p = %{
        emission_us: 100_000,
        burst: 2,
        cost: 1,
        cap: -1,
        limit: 10,
        period_us: 1_000_000,
        offset_us: 0
      }

      {:allowed, _, s} = Gcra.step(nil, p, @t0)
      {:allowed, _, s} = Gcra.step(s, p, @t0)
      {:limited, %{retry_after_us: retry}, ^s} = Gcra.step(s, p, @t0 + 10_000)
      assert {:limited, _, _} = Gcra.step(s, p, @t0 + 10_000 + retry - 1)
      assert {:allowed, _, _} = Gcra.step(s, p, @t0 + 10_000 + retry)
    end
  end

  describe "T-9 (4) G1–G9 on Valkey" do
    @describetag :integration

    setup do
      await_valkey(100)
    end

    test "T-20: the Valkey script gives the vector results" do
      script = Script.new("gcra_at", File.read!("test/support/valkey/gcra_at.lua"))

      for vector <- @vectors["vectors"] do
        scope = Relay.Scope.new!(Relay.Id.generate(), :test)
        {:ok, key} = Scripts.key(scope, ["rl", "g"], "vec.gcra:" <> vector["id"])

        run(vector, fn p, now ->
          args = [p.emission_us, p.burst, p.cost, p.cap, p.limit, p.period_us, p.offset_us, now]
          {:ok, [code, retry, tat, _now, _est]} = Valkey.eval(script, key, args)
          {Enum.at(~w(allowed limited ceiling cost_exceeds_burst), code), retry, tat}
        end)

        if vector["empty_after"],
          do: assert({:ok, 0} = Valkey.adapter().command(["EXISTS", key.name]))
      end
    end

    test "T-9: the test copy of the script differs from the production script only in its clock line" do
      for name <- ~w(gcra window rate_ring) do
        prod = File.read!(Script.path(name)) |> String.split("\n")
        copy = File.read!("test/support/valkey/#{name}_at.lua") |> String.split("\n")
        assert length(prod) == length(copy), name
        diff = for {a, b} <- Enum.zip(prod, copy), a != b, do: {a, b}

        assert [
                 {"local now = (function() local t = redis.call('TIME')" <> _,
                  "local now = tonumber(ARGV[#ARGV])"}
               ] = diff,
               name
      end
    end
  end

  describe "T-9 (4) G1–G9 on PostgreSQL" do
    @describetag :integration

    test "T-20: relay_private.rl_gcra_at gives the vector results in one statement" do
      conn = connect(:admin)

      for vector <- @vectors["vectors"] do
        rolled_back(conn, fn ->
          tenant = tenant!()
          rows("SET LOCAL ROLE relay_owner", [])
          "active" = ctx(tenant)
          key = "vec.gcra:" <> vector["id"]

          run(vector, fn p, now ->
            [[code, retry, tat, ^now]] =
              rows(
                "SELECT * FROM relay_private.rl_gcra_at($1, $2, $3, $4, $5, $6, $7, $8, $9)",
                [
                  now,
                  key,
                  p.emission_us,
                  p.burst,
                  p.cost,
                  p.cap,
                  p.limit,
                  p.period_us,
                  p.offset_us
                ]
              )

            {code, retry, tat}
          end)

          if vector["empty_after"],
            do: assert(rows("SELECT count(*) FROM relay_queue.limiter_states", []) == [[0]])
        end)
      end

      GenServer.stop(conn)
    end

    test "T-20 (1): the application cannot call the clock-injected function" do
      conn = connect("relay_worker")

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(
                 conn,
                 "SELECT * FROM relay_private.rl_gcra_at(0, 'a.b.c:d', 1, 1, 1, -1, 1, 1, 0)",
                 []
               )

      GenServer.stop(conn)
    end
  end
end
