defmodule Relay.Platform.PartitionMaintenanceTest do
  use ExUnit.Case, async: true

  alias Relay.Platform.Maintenance.Partitions

  @days14 %Postgrex.Interval{days: 14}
  @months2 %Postgrex.Interval{months: 2}
  @days3 %Postgrex.Interval{days: 3}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:tzdata)
    :ok
  end

  describe "OP-13 partition planning" do
    test "OP-13: daily partitions are planned up to fourteen days ahead on UTC midnights" do
      now = ~U[2026-10-16 13:45:00Z]
      plan = Partitions.plan(%{interval: :day, premake: @days14}, nil, now)

      assert hd(plan) == {~U[2026-10-16 00:00:00.000000Z], ~U[2026-10-17 00:00:00.000000Z]}
      assert {_, ~U[2026-10-31 00:00:00.000000Z]} = List.last(plan)
      assert length(plan) == 15

      assert Enum.all?(Enum.zip(plan, tl(plan)), fn {{_, to}, {from, _}} -> to == from end)
    end

    test "OP-13: planning continues from the furthest bound and is empty once the horizon is covered" do
      now = ~U[2026-10-16 13:45:00Z]
      policy = %{interval: :day, premake: @days14}

      assert Partitions.plan(policy, ~U[2026-10-29 00:00:00Z], now) == [
               {~U[2026-10-29 00:00:00.000000Z], ~U[2026-10-30 00:00:00.000000Z]},
               {~U[2026-10-30 00:00:00.000000Z], ~U[2026-10-31 00:00:00.000000Z]}
             ]

      assert Partitions.plan(policy, ~U[2026-10-31 00:00:00Z], now) == []
    end

    test "OP-13: monthly partitions cover two months ahead across a year boundary" do
      now = ~U[2026-12-20 08:00:00Z]

      assert Partitions.plan(%{interval: :month, premake: @months2}, nil, now) == [
               {~U[2026-12-01 00:00:00.000000Z], ~U[2027-01-01 00:00:00.000000Z]},
               {~U[2027-01-01 00:00:00.000000Z], ~U[2027-02-01 00:00:00.000000Z]},
               {~U[2027-02-01 00:00:00.000000Z], ~U[2027-03-01 00:00:00.000000Z]}
             ]
    end

    test "OP-13: the horizon alarm fires when the furthest bound is closer than three days" do
      now = ~U[2026-10-16 12:00:00Z]
      assert Partitions.alarm?(nil, @days3, now)
      assert Partitions.alarm?(~U[2026-10-19 11:59:59Z], @days3, now)
      refute Partitions.alarm?(~U[2026-10-19 12:00:00Z], @days3, now)
    end
  end
end

defmodule Relay.Platform.PartitionMaintenanceDatabaseTest do
  use Relay.MaintenanceCase, async: false

  alias Relay.Platform.Maintenance.EscapeHatch
  alias Relay.Platform.Maintenance.PartitionTask

  @seed %{
    "delivery_events" => {"day", 14, 90},
    "delivery_attempts" => {"day", 14, 90},
    "idempotency_keys" => {"day", 14, 90},
    "audit_log" => {"month", 2, 13},
    "dead_letters" => {"month", 2, 13},
    "outbox_events" => {"month", 2, 13},
    "usage_records" => {"month", 2, 13}
  }

  test "OP-13: the policy seed has daily and monthly tables with a three-day alarm and 90-day or 13-month hot storage" do
    committed(fn ->
      {:ok, policies} = EscapeHatch.partition_policies()

      assert Map.new(policies, fn p ->
               {p.table_name,
                {Atom.to_string(p.interval), p.premake.days + p.premake.months,
                 p.hot_retention.days + p.hot_retention.months}}
             end) == @seed

      assert Enum.all?(policies, &(&1.alarm == %Postgrex.Interval{days: 3}))
    end)
  end

  test "OP-13: a maintenance step brings every table past its horizon and leaves no DEFAULT partition" do
    committed(fn ->
      assert {:ok, %{"detached" => detached}, _delay} =
               PartitionTask.run(%{
                 name: "partition_maintenance",
                 node: "t",
                 fencing_token: 1,
                 state: nil
               })

      assert is_list(detached)
      {:ok, horizon} = EscapeHatch.partition_horizon()
      assert Enum.all?(horizon, & &1.ok)

      assert maint_rows!("""
             SELECT count(*) FROM pg_catalog.pg_partitioned_table p
             JOIN pg_catalog.pg_class c ON c.oid = p.partrelid
             JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'relay' AND p.partdefid <> 0
             """) == [[0]]
    end)
  end

  test "OP-14: partitions are created standalone, checked and attached, and an existing range is reported" do
    committed(fn ->
      from =
        DateTime.new!(
          Date.new!(1990 + :rand.uniform(9), 1 + :rand.uniform(11), 1 + :rand.uniform(27)),
          ~T[00:00:00],
          "Etc/UTC"
        )

      to = DateTime.add(from, 1, :day)

      assert {:ok, "created"} = EscapeHatch.partition_create("delivery_attempts", from, to)
      assert {:ok, "exists"} = EscapeHatch.partition_create("delivery_attempts", from, to)
      assert {:ok, "policy_missing"} = EscapeHatch.partition_create("deliveries", from, to)
    end)
  end

  test "OP-15: a partition past hot retention is detached concurrently and handed to the archive role" do
    committed(fn ->
      from =
        DateTime.new!(
          Date.new!(1970 + :rand.uniform(19), 1 + :rand.uniform(11), 1 + :rand.uniform(27)),
          ~T[00:00:00],
          "Etc/UTC"
        )

      {:ok, "created"} =
        EscapeHatch.partition_create("delivery_attempts", from, DateTime.add(from, 1, :day))

      {:ok, due} = EscapeHatch.partitions_due_for_archive()

      assert %{partition_name: name} =
               Enum.find(
                 due,
                 &(DateTime.compare(&1.upper_bound, DateTime.add(from, 1, :day)) == :eq)
               )

      assert :ok = EscapeHatch.detach("delivery_attempts", name)
      assert {:ok, [^name]} = EscapeHatch.detached_partitions([name])
      assert {:ok, []} = EscapeHatch.pending_detaches()
    end)
  end
end
