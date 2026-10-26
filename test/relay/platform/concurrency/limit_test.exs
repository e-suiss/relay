defmodule Relay.Platform.Concurrency.LimitTest do
  use ExUnit.Case, async: false

  @moduletag :real_engine
  @moduletag :integration

  import Relay.SqlCase, only: [connect: 1, committed: 2, tenant!: 0, rows: 2]

  alias Relay.Platform.Concurrency
  alias Relay.Platform.Concurrency.Keeper
  alias Relay.Platform.Valkey

  @nodes 8
  @jobs_per_node 100
  @limit 10

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

  defp valkey_opts, do: [backend: __MODULE__.Unstarted]

  defp track(meter) do
    n = :atomics.add_get(meter, 1, 1)
    raise_max(meter, n)
    Process.sleep(2)
    :atomics.sub(meter, 1, 1)
  end

  defp raise_max(meter, n) do
    seen = :atomics.get(meter, 2)

    if n > seen and :atomics.compare_exchange(meter, 2, seen, n) != :ok,
      do: raise_max(meter, n)
  end

  defp until_granted(fun) do
    case fun.() do
      :ok ->
        :ok

      :full ->
        Process.sleep(1)
        until_granted(fun)
    end
  end

  defp run_worker(job, meter, node, worker, index, jobs) do
    for j <- 1..jobs, do: job.(meter, "oban:#{node}-#{worker}-#{j}", index)
  end

  defp run_nodes(workers_per_node, job) do
    meter = :atomics.new(2, [])
    jobs_per_worker = div(@jobs_per_node, workers_per_node)

    for node <- 1..@nodes, worker <- 1..workers_per_node do
      index = (node - 1) * workers_per_node + worker - 1

      Task.async(fn -> run_worker(job, meter, node, worker, index, jobs_per_worker) end)
    end
    |> Task.await_many(120_000)

    {:atomics.get(meter, 1), :atomics.get(meter, 2)}
  end

  describe "T-22 TN-54 cluster-wide limit on Valkey" do
    setup do
      await_valkey(100)
      %{scope: Relay.Scope.new!(Relay.Id.generate(), :test)}
    end

    test "T-22: eight nodes running 100 jobs each never hold more than the limit of 10", %{
      scope: scope
    } do
      key = "cc.tenant_channel:push"

      {in_flight, max} =
        run_nodes(10, fn meter, holder, _index ->
          until_granted(fn ->
            case Concurrency.acquire(scope, key, @limit, holder, valkey_opts()) do
              {:ok, _} -> :ok
              {:full, _} -> :full
            end
          end)

          track(meter)
          :ok = Concurrency.release(scope, key, holder, valkey_opts())
        end)

      assert in_flight == 0
      assert max <= @limit
      assert max >= 2
    end

    test "T-22: a holder that dies frees its slot when the lease ends", %{scope: scope} do
      opts = valkey_opts() ++ [lease_ms: 300]
      assert {:ok, 1} = Concurrency.acquire(scope, "cc.tenant_deliveries", 1, "oban:dead", opts)

      assert {:full, wait} =
               Concurrency.acquire(scope, "cc.tenant_deliveries", 1, "oban:next", opts)

      assert wait in 1..300
      Process.sleep(400)
      assert {:ok, 1} = Concurrency.acquire(scope, "cc.tenant_deliveries", 1, "oban:next", opts)
    end

    test "T-22: the keeper renews a running job's lease and releases it when the job crashes", %{
      scope: scope
    } do
      keeper =
        start_supervised!({Keeper, name: __MODULE__.Keeper, renew_ms: 50})

      opts = valkey_opts() ++ [lease_ms: 200]
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Concurrency.with_slot(
            scope,
            "cc.provider_account:acct_1",
            1,
            "oban:held",
            fn ->
              send(parent, :holding)
              Process.sleep(:infinity)
            end,
            opts ++ [keeper: keeper]
          )
        end)

      assert_receive :holding, 2_000
      Process.sleep(500)

      assert {:full, _} =
               Concurrency.acquire(scope, "cc.provider_account:acct_1", 1, "oban:other", opts)

      assert Keeper.holders(keeper) == ["oban:held"]

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      eventually(fn -> Keeper.holders(keeper) == [] end)

      assert {:ok, 1} =
               Concurrency.acquire(scope, "cc.provider_account:acct_1", 1, "oban:other", opts)
    end

    test "T-22: a job that finishes releases its slot", %{scope: scope} do
      keeper = start_supervised!({Keeper, name: __MODULE__.Keeper})
      opts = valkey_opts() ++ [keeper: keeper]

      assert {:ok, :done} =
               Concurrency.with_slot(
                 scope,
                 "cc.tenant_deliveries",
                 1,
                 "oban:a",
                 fn -> :done end,
                 opts
               )

      assert {:ok, :done} =
               Concurrency.with_slot(
                 scope,
                 "cc.tenant_deliveries",
                 1,
                 "oban:b",
                 fn -> :done end,
                 opts
               )

      assert_raise RuntimeError, fn ->
        Concurrency.with_slot(
          scope,
          "cc.tenant_deliveries",
          1,
          "oban:c",
          fn -> raise "boom" end,
          opts
        )
      end

      assert {:ok, 1} =
               Concurrency.acquire(scope, "cc.tenant_deliveries", 1, "oban:d", valkey_opts())
    end
  end

  describe "T-22 TN-54 cluster-wide limit on PostgreSQL" do
    setup do
      tenant = committed(connect("relay_worker"), fn -> tenant!() end)
      %{tenant: tenant}
    end

    defp pg(conn, tenant, sql, params) do
      committed(conn, fn ->
        rows("SELECT relay_fn.ctx_set($1, 'test')", [tenant])
        rows(sql, params)
      end)
    end

    test "T-22: eight nodes running 100 jobs each through cc_acquire never hold more than 10", %{
      tenant: tenant
    } do
      conns = for _ <- 1..(@nodes * 4), do: connect("relay_worker")

      {in_flight, max} =
        run_nodes(4, fn meter, holder, index ->
          conn = Enum.at(conns, index)
          key = "cc.tenant_channel:sms"

          until_granted(fn ->
            case pg(conn, tenant, "SELECT result FROM relay_fn.cc_acquire($1, $2, $3, 120000)", [
                   key,
                   @limit,
                   holder
                 ]) do
              [[r]] when r in ["granted", "renewed"] -> :ok
              [["full"]] -> :full
            end
          end)

          track(meter)
          [["released"]] = pg(conn, tenant, "SELECT relay_fn.cc_release($1, $2)", [key, holder])
          :ok
        end)

      Enum.each(conns, &GenServer.stop/1)
      assert in_flight == 0
      assert max <= @limit
    end

    test "T-22: a dead holder's row frees itself when its lease ends", %{tenant: tenant} do
      conn = connect("relay_worker")
      sql = "SELECT * FROM relay_fn.cc_acquire('cc.tenant_deliveries', 1, $1, 300)"
      assert [["granted", 1, 0]] = pg(conn, tenant, sql, ["oban:dead"])
      assert [["full", 1, wait]] = pg(conn, tenant, sql, ["oban:next"])
      assert wait in 0..300
      Process.sleep(400)
      assert [["granted", _, 0]] = pg(conn, tenant, sql, ["oban:next"])
      assert [["renewed", _, 0]] = pg(conn, tenant, sql, ["oban:next"])

      assert [["not_held"]] =
               pg(
                 conn,
                 tenant,
                 "SELECT relay_fn.cc_release('cc.tenant_deliveries', 'oban:dead')",
                 []
               )

      GenServer.stop(conn)
    end

    test "T-22: a lowered limit gives no new holder a slot above it", %{tenant: tenant} do
      conn = connect("relay_worker")

      acquire = fn holder, limit ->
        pg(
          conn,
          tenant,
          "SELECT result FROM relay_fn.cc_acquire('cc.tenant_deliveries', $1, $2, 60000)",
          [limit, holder]
        )
      end

      assert [["granted"]] = acquire.("oban:1", 3)
      assert [["granted"]] = acquire.("oban:2", 3)
      assert [["full"]] = acquire.("oban:3", 2)
      assert [["full"]] = acquire.("oban:3", 1)
      GenServer.stop(conn)
    end
  end

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && eventually(fun, n - 1)
    end
  end
end
