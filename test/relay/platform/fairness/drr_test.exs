defmodule Relay.Platform.Fairness.DrrTest do
  use Relay.SqlCase, async: false

  alias Relay.Tenancy.SettingKeys

  @enqueue "SELECT relay_fn.drr_enqueue($1, $2, $2, 'RelayTest.DrrWorker', $3, $4::smallint, $5, $6, 'delivery', $7, $8)"
  @take "SELECT * FROM relay_ops.drr_take($1, $2, $3, $4)"
  @setting "SELECT * FROM relay_fn.setting_set($1, $2, $3, $4, $5, $6, $7, $8, $9)"

  setup do
    conn = connect(:admin)
    Process.put(:relay_sql_conn, conn)
    rows("BEGIN")
    rows("SET LOCAL ROLE relay_worker")
    :ok
  end

  defp inspecting(fun) do
    rows("RESET ROLE")

    try do
      fun.()
    after
      rows("SET LOCAL ROLE relay_worker")
    end
  end

  defp lease! do
    [result, token] =
      row(
        "SELECT * FROM relay_ops.singleton_acquire('drr_dispatcher', $1, interval '30 seconds')",
        ["test-" <> Base.encode16(:crypto.strong_rand_bytes(4))]
      )

    if result == "held_by_other", do: flunk("drr_dispatcher is leased by another node")
    token
  end

  defp tenant(weights \\ %{}) do
    tenant = tenant!()
    "active" = ctx(tenant)

    for {lane, weight} <- weights,
        do:
          ["created", _] =
            row(@setting, [nil, "fairness.weight.#{lane}", weight, nil, digest() | actor()])

    tenant
  end

  defp enqueue(tenant, lane, opts \\ []) do
    ctx(tenant)

    one(@enqueue, [
      Keyword.get_lazy(opts, :id, &id/0),
      lane,
      %{"n" => Keyword.get(opts, :n, 0)},
      Keyword.get(opts, :priority, 1),
      Keyword.get(opts, :cost, 1),
      Keyword.get_lazy(opts, :at, fn -> DateTime.add(DateTime.utc_now(), -60, :second) end),
      Keyword.get_lazy(opts, :ref, &id/0),
      Keyword.get(opts, :cap, 1_000_000)
    ])
  end

  defp backlog(tenant, lane, count, cost) do
    ctx(tenant)

    one(
      """
      SELECT count(*) FILTER (WHERE r = 'enqueued') FROM (
        SELECT relay_fn.drr_enqueue(uuidv7(), $1, $1, 'RelayTest.DrrWorker', jsonb_build_object('n', g),
          1::smallint, $2, now(), 'delivery', uuidv7(), 1000000) AS r
        FROM generate_series(1, $3) AS g) AS e
      """,
      [lane, cost, count]
    )
  end

  defp take(lane, token, max_jobs, quantum \\ 5_000),
    do: rows(@take, [lane, token, quantum, max_jobs])

  defp taken_by(rows, tenants) do
    counts = Enum.frequencies(for ["dispatched", t | _] <- rows, do: t)
    Enum.map(tenants, &Map.get(counts, &1, 0))
  end

  defp drr_state(tenant, lane) do
    inspecting(fn ->
      row(
        "SELECT weight, deficit, pending_count, pending_cost, active FROM relay_queue.drr_tenants WHERE tenant_id = $1 AND environment = 'test' AND lane = $2",
        [tenant, lane]
      )
    end)
  end

  describe "T-21 DRR rounds" do
    test "T-21: with an unbounded backlog, weights 1 and 3 share the lane 1:3 within one quantum" do
      a = tenant(%{l2: 1})
      b = tenant(%{l2: 3})
      assert backlog(a, "l2", 200, 1_000) == 200
      assert backlog(b, "l2", 200, 1_000) == 200
      token = lease!()

      dispatched =
        for _round <- 1..5, reduce: [] do
          acc -> acc ++ take("l2", token, 1_000)
        end

      [from_a, from_b] = taken_by(dispatched, [a, b])
      assert from_a == 25
      assert abs(from_b * 1_000 - 3 * from_a * 1_000) <= 5_000
    end

    test "T-21: a new tenant's first job waits at most one round behind a tenant with a huge backlog" do
      big = tenant()
      assert backlog(big, "l3", 2_000, 1) == 2_000
      token = lease!()

      first = take("l3", token, 10)
      assert taken_by(first, [big]) == [10]

      newcomer = tenant()
      assert enqueue(newcomer, "l3") == "enqueued"

      second = take("l3", token, 10)
      assert [["dispatched", ^newcomer | _] | _] = second
    end

    test "T-21: a tenant that runs dry ends the round with no deficit and becomes inactive" do
      t = tenant()
      for _ <- 1..2, do: assert(enqueue(t, "l2", cost: 1_000) == "enqueued")
      assert drr_state(t, "l2") == [1, 0, 2, 2_000, true]
      token = lease!()

      assert taken_by(take("l2", token, 100), [t]) == [2]
      assert drr_state(t, "l2") == [1, 0, 0, 0, false]
    end

    test "T-21: a deficit carries over only while due jobs remain" do
      t = tenant()
      for n <- 1..2, do: assert(enqueue(t, "l2", cost: 4_000, n: n) == "enqueued")
      token = lease!()

      assert taken_by(take("l2", token, 100), [t]) == [1]
      assert drr_state(t, "l2") == [1, 1_000, 1, 4_000, true]

      assert taken_by(take("l2", token, 100), [t]) == [1]
      assert drr_state(t, "l2") == [1, 0, 0, 0, false]
    end

    test "T-21: a tenant with only future jobs keeps waiting with no deficit" do
      t = tenant()
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)
      assert enqueue(t, "l3", at: later) == "enqueued"
      token = lease!()

      assert taken_by(take("l3", token, 100), [t]) == [0]
      assert drr_state(t, "l3") == [1, 0, 1, 1, true]
    end

    test "T-21: inside a tenant the jobs leave by priority, then by schedule" do
      t = tenant()
      assert enqueue(t, "l2", priority: 6, n: 1) == "enqueued"
      assert enqueue(t, "l2", priority: 5, n: 2) == "enqueued"
      assert enqueue(t, "l2", priority: 7, n: 3) == "enqueued"
      token = lease!()

      order =
        for ["dispatched", ^t, _env, _id, _queue, _worker, %{"n" => n} | _] <-
              take("l2", token, 100),
            do: n

      assert order == [2, 1, 3]
    end

    test "T-21: a round ends at its job limit and the tenants it did not reach come first next time" do
      a = tenant()
      b = tenant()
      assert backlog(a, "l2", 10, 1) == 10
      assert backlog(b, "l2", 10, 1) == 10
      token = lease!()

      first = take("l2", token, 10)
      assert Enum.sum(taken_by(first, [a, b])) == 10
      [["dispatched", served | _] | _] = first
      waiting = if served == a, do: b, else: a

      assert [["dispatched", ^waiting | _] | _] = take("l2", token, 5)
    end

    test "T-21 (3): a cancelled job is never dispatched" do
      t = tenant()
      ref = id()
      assert enqueue(t, "l3", ref: ref, n: 1) == "enqueued"
      assert enqueue(t, "l3", ref: ref, n: 2) == "enqueued"
      assert enqueue(t, "l3", n: 3) == "enqueued"

      assert row("SELECT * FROM relay_fn.drr_cancel('delivery', $1, 'notification.cancelled')", [
               ref
             ]) ==
               ["cancelled", 2]

      assert row("SELECT * FROM relay_fn.drr_cancel('delivery', $1, 'notification.cancelled')", [
               ref
             ]) ==
               ["none", 0]

      assert drr_state(t, "l3") == [1, 0, 1, 1, true]
      token = lease!()

      assert [%{"n" => 3}] =
               for(["dispatched", ^t, _, _, _, _, args | _] <- take("l3", token, 100), do: args)

      assert inspecting(fn ->
               rows(
                 "SELECT state, cancel_rule_id FROM relay_queue.drr_waits WHERE tenant_id = $1 ORDER BY args->>'n'",
                 [t]
               )
             end) == [
               ["cancelled", "notification.cancelled"],
               ["cancelled", "notification.cancelled"],
               ["dispatched", nil]
             ]
    end

    test "T-21 (2): a round under a stale fencing token is refused and moves nothing" do
      t = tenant()
      assert enqueue(t, "l2") == "enqueued"
      token = lease!()

      assert take("l2", token + 1, 100) == [
               ["not_leader", nil, nil, nil, nil, nil, nil, nil, nil]
             ]

      assert drr_state(t, "l2") == [1, 0, 1, 1, true]
    end

    test "T-21 (2): the round counter lives in the dispatcher's task state" do
      token = lease!()
      _ = take("l2", token, 1)
      _ = take("l2", token, 1)

      assert one(
               "SELECT (state -> 'l2' ->> 'round')::bigint >= 2 FROM relay.singleton_tasks WHERE name = 'drr_dispatcher'"
             )
    end
  end

  describe "T-21 (4) T-91 (2) TN-54 the wait table" do
    test "T-21 (4): security and l1 jobs never enter the wait table" do
      t = tenant()
      assert enqueue(t, "l0") == "lane_not_fair"
      assert enqueue(t, "l1") == "lane_not_fair"

      inspecting(fn ->
        assert one("SELECT count(*) FROM relay_queue.drr_waits WHERE tenant_id = $1", [t]) == 0
        assert one("SELECT count(*) FROM relay_queue.drr_tenants WHERE tenant_id = $1", [t]) == 0
      end)
    end

    test "TN-54: a tenant's waiting jobs in a lane stop at its cap" do
      t = tenant()
      assert enqueue(t, "l2", cap: 2) == "enqueued"
      assert enqueue(t, "l2", cap: 2) == "enqueued"
      assert enqueue(t, "l2", cap: 2) == "queued_cap_exceeded"
      assert enqueue(t, "l3", cap: 2) == "enqueued"
      assert drr_state(t, "l2") == [1, 0, 2, 2, true]
    end

    test "T-21: the same job id is written once" do
      t = tenant()
      job = id()
      assert enqueue(t, "l2", id: job) == "enqueued"
      assert enqueue(t, "l2", id: job) == "exists"
      assert drr_state(t, "l2") == [1, 0, 1, 1, true]
    end

    test "T-21 (2): no job is larger than the quantum, and no quantum is smaller than the largest job" do
      t = tenant()
      assert enqueue(t, "l2", cost: 5_000) == "enqueued"

      assert error_message(@enqueue, [id(), "l2", %{}, 1, 5_001, DateTime.utc_now(), id(), 10]) ==
               "invalid_argument"

      token = lease!()
      assert error_message(@take, ["l2", token, 4_999, 10]) == "invalid_argument"
    end

    test "OP-74: wait rows carry identifiers only and a bounded payload" do
      t = tenant()
      big = %{"ids" => for(_ <- 1..60, do: Ecto.UUID.generate())}

      assert error_message(@enqueue, [id(), "l2", big, 1, 1, DateTime.utc_now(), id(), 10]) ==
               "invalid_argument"

      assert enqueue(t, "l2") == "enqueued"
    end

    test "T-21 (2): weights come from the tenant settings and refresh under the dispatcher's token" do
      t = tenant()
      assert enqueue(t, "l2") == "enqueued"
      assert hd(drr_state(t, "l2")) == 1

      ["created", _] = row(@setting, [nil, "fairness.weight.l2", 4, nil, digest() | actor()])
      token = lease!()

      assert row("SELECT * FROM relay_ops.drr_weights_refresh('l2', $1)", [token + 1]) == [
               "not_leader",
               0
             ]

      assert ["refreshed", updated] =
               row("SELECT * FROM relay_ops.drr_weights_refresh('l2', $1)", [token])

      assert updated >= 1
      assert hd(drr_state(t, "l2")) == 4
    end

    test "T-21 (2): a weight outside 1 to 100 falls back to 1" do
      for {value, expected} <- [{0, 1}, {101, 1}, {2.5, 1}, {"7", 1}, {7, 7}, {100, 100}] do
        t = tenant()

        ["created", _] =
          row(@setting, [nil, "fairness.weight.l3", value, nil, digest() | actor()])

        assert enqueue(t, "l3") == "enqueued"
        assert hd(drr_state(t, "l3")) == expected, inspect(value)
      end
    end

    test "T-21 (2): the setting catalog takes fairness weights from 1 to 100" do
      assert SettingKeys.cast("fairness.weight.l3", 100) == {:ok, 100}

      assert {:error, %Relay.Error{code: :invalid_setting}} =
               SettingKeys.cast("fairness.weight.l2", 0)

      assert {:error, %Relay.Error{code: :unknown_setting}} =
               SettingKeys.cast("fairness.weight.l1", 1)
    end
  end
end
