defmodule Relay.Platform.Concurrency.DrrRaceTest do
  use Relay.SqlCase, async: false

  @moduletag :real_engine

  @enqueue "SELECT relay_fn.drr_enqueue($1, 'l2', 'l2', 'RelayTest.DrrWorker', $2, 1::smallint, $3, now() - interval '1 minute', 'fanout_slice', $4, 1000000)"
  @take "SELECT * FROM relay_ops.drr_take('l2', $1, 5000, $2)"
  @lease "SELECT * FROM relay_ops.singleton_acquire('drr_dispatcher', $1, interval '1 second')"

  defp worker_conn, do: connect("relay_worker")

  defp tx(conn, fun) do
    Postgrex.query!(conn, "BEGIN", [])
    result = fun.()
    Postgrex.query!(conn, "COMMIT", [])
    result
  end

  defp tenant(conn, weight) do
    on(conn, fn ->
      committed(conn, fn ->
        t = tenant!()
        "active" = ctx(t)

        ["created", _] =
          row("SELECT * FROM relay_fn.setting_set($1, $2, $3, $4, $5, $6, $7, $8, $9)", [
            nil,
            "fairness.weight.l2",
            weight,
            nil,
            digest() | actor()
          ])

        t
      end)
    end)
  end

  defp produce(tenant, ref, count, cost) do
    conn = worker_conn()

    for n <- 1..count do
      job = id()

      %{rows: [["enqueued"]]} =
        tx(conn, fn ->
          Postgrex.query!(conn, "SELECT relay_fn.ctx_set($1, 'test')", [tenant])
          Postgrex.query!(conn, @enqueue, [job, %{"n" => n}, cost, ref])
        end)

      job
    end
  end

  defp lease!(conn, node) do
    %{rows: [[result, token]]} = Postgrex.query!(conn, @lease, [node])
    {result, token}
  end

  defp take(conn, token, max_jobs) do
    tx(conn, fn -> Postgrex.query!(conn, @take, [token, max_jobs]).rows end)
  end

  defp cancel(conn, tenant, ref) do
    tx(conn, fn ->
      Postgrex.query!(conn, "SELECT relay_fn.ctx_set($1, 'test')", [tenant])

      Postgrex.query!(
        conn,
        "SELECT * FROM relay_fn.drr_cancel('fanout_slice', $1, 'test.cleanup')",
        [ref]
      )
    end)
  end

  defp wait_for_lease_expiry, do: Process.sleep(1_100)

  defp ours(rows, tenants),
    do: for(["dispatched", t, _env, id | _] <- rows, t in tenants, do: {t, id})

  describe "T-61 T-21 DRR on the real engine" do
    test "T-21: concurrent producers on separate connections share the lane by weight, 1:3" do
      setup_conn = worker_conn()
      a = tenant(setup_conn, 1)
      b = tenant(setup_conn, 3)
      ref_a = id()
      ref_b = id()

      [_jobs_a, _jobs_b] =
        [{a, ref_a}, {b, ref_b}]
        |> Enum.map(fn {t, ref} -> Task.async(fn -> produce(t, ref, 100, 1_000) end) end)
        |> Enum.map(&Task.await(&1, 60_000))

      dispatcher = worker_conn()
      {"acquired", token} = lease!(dispatcher, "race-ratio")

      taken =
        for _round <- 1..4, reduce: [] do
          acc -> acc ++ ours(take(dispatcher, token, 1_000), [a, b])
        end

      counts = Enum.frequencies_by(taken, &elem(&1, 0))
      assert counts[a] == 20
      assert counts[b] == 60

      cancel(setup_conn, a, ref_a)
      cancel(setup_conn, b, ref_b)
      wait_for_lease_expiry()
    end

    test "T-21: while producers and the dispatcher race, every job is dispatched exactly once" do
      setup_conn = worker_conn()
      tenants = for _ <- 1..3, do: tenant(setup_conn, 1)
      refs = Map.new(tenants, &{&1, id()})

      producers =
        for t <- tenants, _ <- 1..2, do: Task.async(fn -> produce(t, refs[t], 40, 500) end)

      dispatcher = worker_conn()

      dispatched =
        Stream.repeatedly(fn ->
          {result, token} = lease!(dispatcher, "race-dispatcher")
          assert result in ["acquired", "renewed"]
          ours(take(dispatcher, token, 25), tenants)
        end)
        |> Stream.transform(0, fn batch, idle ->
          done = not Enum.any?(producers, &Process.alive?(&1.pid))
          idle = if batch == [] and done, do: idle + 1, else: 0
          if idle >= 3, do: {:halt, idle}, else: {[batch], idle}
        end)
        |> Enum.to_list()
        |> List.flatten()

      produced = producers |> Enum.flat_map(&Task.await(&1, 60_000)) |> MapSet.new()

      ids = Enum.map(dispatched, &elem(&1, 1))
      assert length(ids) == length(Enum.uniq(ids)), "a job was dispatched twice"
      assert MapSet.new(ids) == produced, "a job was lost"
      assert MapSet.size(produced) == 240

      admin = connect(:admin)

      pending =
        Postgrex.query!(
          admin,
          "SELECT sum(pending_count)::bigint, bool_or(active) FROM relay_queue.drr_tenants WHERE tenant_id = ANY($1) AND lane = 'l2'",
          [tenants]
        ).rows

      assert pending == [[0, false]]
      wait_for_lease_expiry()
    end

    test "T-21 (2): when the lease moves to a second candidate, the first one's round is refused" do
      first = worker_conn()
      second = worker_conn()
      setup_conn = worker_conn()
      t = tenant(setup_conn, 1)
      ref = id()
      [job] = produce(t, ref, 1, 1)

      {"acquired", old} = lease!(first, "race-first")
      wait_for_lease_expiry()
      {"acquired", new} = lease!(second, "race-second")
      assert new > old

      results =
        [{first, old}, {second, new}]
        |> Enum.map(fn {conn, token} -> Task.async(fn -> take(conn, token, 10) end) end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert [[["not_leader" | _]], from_second] = results
      assert {t, job} in ours(from_second, [t])
      wait_for_lease_expiry()
    end
  end
end
