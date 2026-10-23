defmodule Relay.Platform.PartitionStorageTest do
  use Relay.MaintenanceCase, async: false

  alias Relay.Platform.Maintenance.EscapeHatch
  alias Relay.Platform.Maintenance.PartitionTask

  @far_past ~U[1960-03-10 00:00:00Z]

  defp admin do
    {:ok, conn} = Postgrex.start_link(RelayDev.Database.connection(:admin))
    conn
  end

  defp rolled_back(conn, fun),
    do: Postgrex.transaction(conn, fn tx -> Postgrex.rollback(tx, {:done, fun.(tx)}) end)

  defp newest_leaf(conn, table) do
    %{rows: [[leaf, upper]]} =
      Postgrex.query!(
        conn,
        """
        SELECT c.relname::text, relay_private.partition_upper_bound(c.oid)
        FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = format('relay.%I', $1::text)::regclass
        ORDER BY 2 DESC LIMIT 1
        """,
        [table]
      )

    {leaf, upper}
  end

  defp options(conn, leaf) do
    %{rows: [[options, toast]]} =
      Postgrex.query!(
        conn,
        """
        SELECT coalesce(c.reloptions, '{}'), coalesce(t.reloptions, '{}')
        FROM pg_class c LEFT JOIN pg_class t ON t.oid = c.reltoastrelid
        WHERE c.oid = format('relay.%I', $1::text)::regclass
        """,
        [leaf]
      )

    {Enum.sort(options), Enum.sort(toast)}
  end

  defp listen(names) do
    ref = make_ref()
    pid = self()

    :telemetry.attach_many(
      ref,
      names,
      fn event, _measurements, meta, _ -> send(pid, {event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
  end

  defp hold_lock(conn, table) do
    parent = self()

    holder =
      Task.async(fn ->
        Postgrex.transaction(conn, fn tx ->
          Postgrex.query!(tx, "LOCK TABLE relay.#{table} IN ACCESS EXCLUSIVE MODE", [])
          send(parent, :locked)

          receive do
            :release -> Postgrex.rollback(tx, :released)
          end
        end)
      end)

    assert_receive :locked, 5_000
    holder
  end

  defp release(holder) do
    send(holder.pid, :release)
    assert {:error, :released} = Task.await(holder)
  end

  test "OP-14: a new leaf partition takes the storage parameters of the newest leaf" do
    conn = admin()

    assert {:error, {:done, {created, {options, toast}}}} =
             rolled_back(conn, fn tx ->
               {leaf, upper} = newest_leaf(tx, "delivery_events")

               Postgrex.query!(
                 tx,
                 "ALTER TABLE relay.#{leaf} SET (fillfactor = 90, autovacuum_vacuum_scale_factor = 0.02, toast.autovacuum_vacuum_scale_factor = 0.05)",
                 []
               )

               %{rows: [[created]]} =
                 Postgrex.query!(tx, "SELECT relay_private.partition_create($1, $2, $3)", [
                   "delivery_events",
                   upper,
                   DateTime.add(upper, 1, :day)
                 ])

               {new_leaf, _} = newest_leaf(tx, "delivery_events")
               refute new_leaf == leaf
               {created, options(tx, new_leaf)}
             end)

    assert created == "created"
    assert options == ["autovacuum_vacuum_scale_factor=0.02", "fillfactor=90"]
    assert toast == ["autovacuum_vacuum_scale_factor=0.05"]
    GenServer.stop(conn)
  end

  test "OP-14: partition DDL that meets a held lock times out and is deferred, then succeeds" do
    committed(fn ->
      conn = admin()
      holder = hold_lock(conn, "delivery_attempts")
      to = DateTime.add(@far_past, 1, :day)

      assert {:ok, "lock_timeout"} =
               EscapeHatch.partition_create("delivery_attempts", @far_past, to)

      release(holder)

      assert {:error, {:done, "created"}} =
               rolled_back(conn, fn tx ->
                 %{rows: [[result]]} =
                   Postgrex.query!(tx, "SELECT relay_private.partition_create($1, $2, $3)", [
                     "delivery_attempts",
                     @far_past,
                     to
                   ])

                 result
               end)

      GenServer.stop(conn)
    end)
  end

  test "OP-14: a maintenance step that meets a held lock is deferred and the next step completes" do
    listen([[:relay, :partition, :analyzed]])

    context = %{
      name: "partition_maintenance",
      node: "t",
      fencing_token: 1,
      state: %{"analyzed_on" => "2000-01-01"}
    }

    committed(fn ->
      conn = admin()
      holder = hold_lock(conn, "usage_records")

      assert {:error, %Relay.Error{code: :lock_timeout}} = PartitionTask.run(context)
      refute_received {[:relay, :partition, :analyzed], %{table: "usage_records"}}
      release(holder)

      assert {:ok, %{"analyzed_on" => today}, _delay} = PartitionTask.run(context)
      assert today == Date.to_iso8601(Date.utc_today())
      assert_received {[:relay, :partition, :analyzed], %{table: "usage_records"}}
      GenServer.stop(conn)
    end)
  end

  test "OP-14: parent statistics are refreshed once per UTC day" do
    listen([[:relay, :partition, :analyzed]])

    committed(fn ->
      {:ok, policies} = EscapeHatch.partition_policies()
      context = %{name: "partition_maintenance", node: "t", fencing_token: 1}

      assert {:ok, %{"analyzed_on" => today} = state, _delay} =
               PartitionTask.run(Map.put(context, :state, %{"analyzed_on" => "2000-01-01"}))

      for %{table_name: table} <- policies,
          do: assert_received({[:relay, :partition, :analyzed], %{table: ^table}})

      assert {:ok, %{"analyzed_on" => ^today}, _delay} =
               PartitionTask.run(Map.put(context, :state, state))

      refute_received {[:relay, :partition, :analyzed], _}
    end)
  end
end
