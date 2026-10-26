defmodule Relay.Platform.Concurrency.GcraRaceTest do
  use ExUnit.Case, async: false

  @moduletag :real_engine
  @moduletag :integration

  import Relay.SqlCase, only: [connect: 1, committed: 2, tenant!: 0, on: 2, rows: 2]

  alias Relay.Platform.RateLimit.Scripts
  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Script

  @t0 1_700_000_000_000_000

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

  defp params(l, b), do: [div(1_000_000 + l - 1, l), b, 1, -1, l, 1_000_000, 0]

  defp valkey_race(l, b, callers) do
    script = Script.new("gcra_at", File.read!("test/support/valkey/gcra_at.lua"))
    scope = Relay.Scope.new!(Relay.Id.generate(), :test)
    {:ok, key} = Scripts.key(scope, ["rl", "g"], "race.gcra:k")
    args = params(l, b) ++ [@t0]

    1..callers
    |> Enum.map(fn _ -> Task.async(fn -> Valkey.eval(script, key, args) end) end)
    |> Task.await_many(30_000)
    |> Enum.count(&match?({:ok, [0 | _]}, &1))
  end

  defp pg_caller(conn, gate, calls_each, tenant, l, b) do
    wait_open(gate)
    for _ <- 1..calls_each, do: pg_call(conn, tenant, l, b)
  end

  defp pg_call(conn, tenant, l, b) do
    committed(conn, fn ->
      rows("SELECT relay_fn.ctx_set($1, 'test')", [tenant])

      [[result | _]] =
        rows(
          "SELECT * FROM relay_private.rl_gcra_at($1, 'race.gcra:k', $2, $3, $4, $5, $6, $7, $8)",
          [@t0 | params(l, b)]
        )

      result
    end)
  end

  defp pg_race(l, b, connections, calls_each) do
    tenant = committed(connect(:admin), fn -> tenant!() end)

    conns =
      for _ <- 1..connections do
        conn = connect(:admin)
        on(conn, fn -> rows("SET ROLE relay_owner", []) end)
        conn
      end

    gate = :atomics.new(1, [])

    results =
      conns
      |> Enum.map(&Task.async(fn -> pg_caller(&1, gate, calls_each, tenant, l, b) end))
      |> tap(fn _ -> :atomics.put(gate, 1, 1) end)
      |> Task.await_many(60_000)
      |> List.flatten()

    Enum.each(conns, &GenServer.stop/1)
    Enum.count(results, &(&1 == "allowed"))
  end

  defp wait_open(gate) do
    if :atomics.get(gate, 1) == 0 do
      Process.sleep(1)
      wait_open(gate)
    end
  end

  describe "T-18 T-61 (3) known limiter races on the real engines" do
    setup do
      await_valkey(100)
    end

    test "T-18: G4 initialisation race: 50 concurrent first calls on an empty key allow exactly one" do
      assert valkey_race(1, 1, 50) == 1
      assert pg_race(1, 1, 50, 1) == 1
    end

    test "T-18: G10 CAS race: 200 concurrent calls from four nodes allow exactly the burst of 100" do
      assert valkey_race(100, 100, 200) == 100
      assert pg_race(100, 100, 40, 5) == 100
    end
  end
end
