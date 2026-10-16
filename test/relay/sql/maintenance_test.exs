defmodule Relay.Sql.MaintenanceTest do
  use Relay.SqlCase, async: false

  @create "SELECT relay_private.partition_create($1, $2::text::timestamptz, $3::text::timestamptz)"

  defp as_maint(fun) do
    rolled_back(connect("relay_maint"), fn ->
      rows("SET LOCAL TimeZone = 'UTC'")
      fun.()
    end)
  end

  test "OP-14: partition_create builds, secures and attaches a leaf once" do
    as_maint(fn ->
      assert one(@create, ["delivery_events", "2030-03-01 00:00:00+00", "2030-03-02 00:00:00+00"]) ==
               "created"

      assert one(@create, ["delivery_events", "2030-03-01 00:00:00+00", "2030-03-02 00:00:00+00"]) ==
               "exists"

      assert one(@create, ["notifications", "2030-03-01 00:00:00+00", "2030-03-02 00:00:00+00"]) ==
               "policy_missing"

      assert error_message(@create, [
               "delivery_events",
               "2030-03-01 06:00:00+00",
               "2030-03-02 06:00:00+00"
             ]) == "invalid_argument"

      assert row(
               "SELECT c.relrowsecurity, c.relforcerowsecurity, c.relispartition FROM pg_class c WHERE c.oid = 'relay.delivery_events_p20300301'::regclass"
             ) == [true, true, true]

      assert rows(
               "SELECT policyname::text FROM pg_policies WHERE schemaname = 'relay' AND tablename = 'delivery_events_p20300301'"
             ) == [["delivery_events_p20300301_scope"]]

      assert rows(
               "SELECT tgname::text FROM pg_trigger WHERE tgrelid = 'relay.delivery_events_p20300301'::regclass AND NOT tgisinternal AND (tgtype & 32) <> 0"
             ) == [["delivery_events_p20300301_no_truncate"]]

      assert one(
               "SELECT has_table_privilege('relay_maint', 'relay.delivery_events_p20300301', 'SELECT') AND NOT has_table_privilege('relay_api', 'relay.delivery_events_p20300301', 'SELECT')"
             )
    end)
  end

  test "OP-14: monthly tables take month-aligned bounds and date keys" do
    as_maint(fn ->
      assert one(@create, ["usage_records", "2030-04-01 00:00:00+00", "2030-05-01 00:00:00+00"]) ==
               "created"

      assert one("SELECT relay_private.parent_analyze('usage_records')") == "analyzed"
    end)
  end

  test "OP-13: the horizon reports the furthest bound per partitioned table" do
    horizon =
      as_maint(fn ->
        "created" =
          one(@create, ["outbox_events", "2030-06-01 00:00:00+00", "2030-07-01 00:00:00+00"])

        rows("SELECT table_name, furthest_bound, ok FROM relay_ops.partition_horizon()")
      end)

    assert ["outbox_events", ~U[2030-07-01 00:00:00.000000Z], true] in horizon
  end

  test "OP-66: every partitioned table is within its horizon after setup" do
    horizon = rows("SELECT table_name, ok FROM relay_ops.partition_horizon()")

    assert horizon != []
    assert Enum.all?(horizon, fn [_, ok] -> ok end)
  end

  test "OP-13: partition policies are changed through the audited function" do
    set = "SELECT relay_ops.partition_policy_set($1, $2, $3, $4, $5, $6, $7, $8, $9)"

    [interval, premake, hot] =
      row(
        "SELECT partition_interval, premake_horizon, hot_retention FROM relay.partition_policies WHERE table_name = 'delivery_events'"
      )

    assert one(set, ["delivery_events", interval, premake, hot, digest() | actor()]) ==
             "unchanged"

    assert one(set, [
             "delivery_events",
             interval,
             premake,
             %Postgrex.Interval{days: 91},
             digest() | actor()
           ]) == "updated"

    assert one(set, ["notifications", "day", premake, hot, digest() | actor()]) ==
             "not_partitioned"
  end

  test "T-12: one leader at a time with a fencing token that grows on takeover" do
    worker = connect("relay_worker")
    name = "sqltest_" <> Base.encode16(digest())
    acquire = "SELECT * FROM relay_ops.singleton_acquire($1, $2, '1 minute')"
    save = "SELECT relay_ops.singleton_save($1, $2, $3)"

    committed(worker, fn ->
      assert row(acquire, [name, "node_a"]) == ["acquired", 1]
      assert row(acquire, [name, "node_a"]) == ["renewed", 1]
      assert row(acquire, [name, "node_b"]) == ["held_by_other", nil]
      assert one(save, [name, 1, %{"cursor" => 1}]) == "saved"
    end)

    committed(connect(:admin), fn ->
      rows(
        "UPDATE relay.singleton_tasks SET lease_until = now() - interval '1 second' WHERE name = $1",
        [name]
      )
    end)

    committed(worker, fn ->
      assert row(acquire, [name, "node_b"]) == ["acquired", 2]
      assert one(save, [name, 1, %{"cursor" => 2}]) == "not_leader"
      assert one(save, [name, 2, %{"cursor" => 2}]) == "saved"
    end)
  end

  test "OP-42: the orphan check reports every check with a count" do
    checks =
      as_maint(fn ->
        rows("SELECT check_name, table_name, violations FROM relay_ops.orphan_check()")
      end)

    names = checks |> Enum.map(&hd/1) |> Enum.uniq()

    for name <-
          ~w(null_scope tenant_missing ledger_attempt_missing audit_leaf_without_record audit_target_missing) do
      assert name in names
    end

    assert Enum.all?(checks, fn [_, _, count] -> is_integer(count) end)
  end
end
