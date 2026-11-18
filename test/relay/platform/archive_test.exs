defmodule Relay.Platform.ArchiveTest do
  use Relay.MaintenanceCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.ObjectStore.S3
  alias Relay.Platform.ArchiveRepo
  alias Relay.Platform.Maintenance.Archive
  alias Relay.Platform.Maintenance.ArchiveStore
  alias Relay.Platform.Maintenance.ArchiveTask
  alias Relay.Platform.Maintenance.EscapeHatch
  alias Relay.Platform.Maintenance.Restore
  alias Relay.Platform.MaintRepo
  alias RelayDev.ObjectStore

  @table "usage_records"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:req)
    store = ArchiveTask.store()
    :ok = ObjectStore.setup(store)
    %{store: store}
  end

  setup do
    start_supervised!(ArchiveRepo)
    :ok
  end

  defp archived(fun),
    do: committed(fn -> Sandbox.unboxed_run(ArchiveRepo, fun) end)

  defp admin do
    {:ok, conn} = Postgrex.start_link(RelayDev.Database.connection(:admin))
    conn
  end

  defp token do
    [[_result, token]] =
      rows!(
        "SELECT * FROM relay_ops.singleton_acquire('partition_archive', $1, interval '10 minutes')",
        ["archive-test"]
      )

    token
  end

  defp leaf!(month, provider \\ "p\twith\nescapes\\") do
    from = DateTime.new!(Date.new!(1961, month, 1), ~T[00:00:00], "Etc/UTC")
    to = DateTime.shift(from, month: 1)
    {:ok, "created"} = EscapeHatch.partition_create(@table, from, to)
    leaf = @table <> "_p1961" <> String.pad_leading(Integer.to_string(month), 2, "0")
    %{id: tenant} = tenant!()
    conn = admin()

    {:ok, _} =
      Postgrex.transaction(conn, fn tx ->
        Postgrex.query!(tx, "SELECT set_config('relay.tenant_id', $1, true)", [
          Relay.Id.to_string(tenant)
        ])

        Postgrex.query!(tx, "SELECT set_config('relay.environment', 'live', true)", [])

        for {country, day} <- [{"TR", 1}, {nil, 2}, {"DE", 3}] do
          Postgrex.query!(
            tx,
            """
            INSERT INTO relay.usage_records (tenant_id, environment, id, usage_day, channel,
              provider, destination_country, outcome, is_test, quantity, attempt_count, created_at)
            VALUES ($1, 'live', uuidv7(), $2, 'sms', $3, $4, 'accepted', false, 1, 1, now())
            """,
            [tenant, Date.new!(1961, month, day), provider, country]
          )
        end
      end)

    :ok = EscapeHatch.detach(@table, leaf)
    %{rows: rows} = Postgrex.query!(conn, "SELECT t::text FROM relay.#{leaf} t ORDER BY id", [])
    GenServer.stop(conn)
    {leaf, rows}
  end

  defp waiting(leaf) do
    {:ok, leaves} = ArchiveStore.leaves()
    Enum.find(leaves, &(&1.leaf_name == leaf))
  end

  defp exists?(leaf),
    do: rows!("SELECT to_regclass($1) IS NOT NULL", ["relay." <> leaf]) == [[true]]

  defp manifests(leaf),
    do:
      maint_rows!(
        "SELECT id, status, failure_code, row_count FROM relay.archive_manifests WHERE leaf_name = $1 ORDER BY started_at",
        [leaf]
      )

  describe "OP-84 cold archive" do
    test "OP-84: a detached leaf is written as Parquet, uploaded locked, read back, verified and only then removed",
         %{store: store} do
      archived(fn ->
        {leaf, rows} = leaf!(1)
        entry = waiting(leaf)
        assert %{table_name: @table, retain_days: 0} = entry

        assert {:ok, %{rows: 3, digest: digest, id: id}} = Archive.run(entry, token(), store)

        refute exists?(leaf)
        assert waiting(leaf) == nil
        assert [[^id, "archived", nil, 3]] = manifests(leaf)

        [[object_key, schema_key, stored_digest]] =
          maint_rows!(
            "SELECT object_key, schema_key, digest FROM relay.archive_manifests WHERE id = $1",
            [id]
          )

        assert stored_digest == digest
        assert {:ok, {"GOVERNANCE", _until}} = ObjectStore.retention(store, object_key)
        assert {:ok, schema} = S3.get(store, schema_key)

        assert %{"table" => @table, "leaf" => ^leaf, "rows" => 3, "columns" => columns} =
                 Jason.decode!(schema)

        assert %{"name" => "tenant_id", "type" => "uuid", "key_position" => 1} = hd(columns)

        schema_name = "restore_" <> leaf
        assert {:ok, %{rows: 3}} = Restore.run(id, schema_name)

        conn = admin()

        %{rows: restored} =
          Postgrex.query!(conn, "SELECT t::text FROM #{schema_name}.#{leaf} t ORDER BY id", [])

        assert restored == rows

        assert {:error, %Postgrex.Error{}} =
                 Postgrex.query(conn, "UPDATE #{schema_name}.#{leaf} SET quantity = 2", [])

        Postgrex.query!(conn, "DROP SCHEMA #{schema_name} CASCADE", [])
        GenServer.stop(conn)
      end)
    end

    test "OP-15: a failed attempt leaves the leaf detached and the next attempt starts from scratch",
         %{store: store} do
      archived(fn ->
        {leaf, _rows} = leaf!(2)
        entry = waiting(leaf)
        broken = [executable: "/nonexistent/archive_port", sha256: String.duplicate("0", 64)]

        assert {:error, %Relay.Error{code: :parquet_integrity}} =
                 Archive.run(entry, token(), store, broken)

        assert exists?(leaf)
        assert [[_id, "failed", "parquet_integrity", nil]] = manifests(leaf)

        assert {:ok, %{rows: 3}} = Archive.run(waiting(leaf), token(), store)
        refute exists?(leaf)
        assert [[_, "failed", _, _], [_, "archived", nil, 3]] = manifests(leaf)
      end)
    end

    test "INV-47: the hot copy is never removed before verification, nor when the leaf changed after it",
         %{store: store} do
      archived(fn ->
        {leaf, _rows} = leaf!(3)
        token = token()
        id = Relay.Id.generate()

        manifest = %{
          id: id,
          table_name: @table,
          leaf_name: leaf,
          object_key: "test/#{leaf}.parquet",
          schema_key: "test/#{leaf}.schema.json",
          retain_until: DateTime.utc_now()
        }

        assert {:ok, _version} = ArchiveStore.begin(manifest, token)

        assert {:error, %Relay.Error{details: %{result: "not_verified"}}} =
                 ArchiveStore.drop(id, token)

        assert exists?(leaf)

        assert :ok =
                 ArchiveStore.verified(id, %{rows: 2, digest: <<0::256>>, bytes: 1}, token)

        assert {:error, %Relay.Error{details: %{result: "count_mismatch"}}} =
                 ArchiveStore.drop(id, token)

        assert exists?(leaf)

        assert rows!(
                 "SELECT relforcerowsecurity FROM pg_class WHERE oid = to_regclass($1)",
                 ["relay." <> leaf]
               ) == [[true]]

        assert {:error, %Relay.Error{details: %{result: "not_leader"}}} =
                 ArchiveStore.drop(id, token + 1_000_000)

        assert {:ok, %{rows: 3}} = Archive.run(waiting(leaf), token(), store)
        refute exists?(leaf)
      end)
    end

    test "INV-47: only relay_archive may remove a hot copy" do
      id = Relay.Id.generate()

      for {repo, label} <- [{Relay.Repo, "relay_worker"}, {MaintRepo, "relay_maint"}] do
        assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
                 committed(fn ->
                   repo.query("SELECT relay_private.archive_drop($1, $2)", [id, 1])
                 end),
               label
      end
    end

    test "OP-84: the archive task moves the oldest detached leaf and reports its backlog" do
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        ref,
        [[:relay, :archive, :archived], [:relay, :archive, :state]],
        fn event, measurements, meta, _ -> send(pid, {event, measurements, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      archived(fn ->
        {leaf, _rows} = leaf!(4)
        context = %{name: "partition_archive", node: "t", fencing_token: token(), state: nil}

        assert {:ok, %{"failures" => 0, "backlog" => backlog}, _delay} = ArchiveTask.run(context)
        refute Map.has_key?(backlog, leaf)
        refute exists?(leaf)
        assert_received {[:relay, :archive, :archived], %{rows: 3}, %{table: @table}}
        assert_received {[:relay, :archive, :state], %{failures: 0}, %{}}
      end)
    end
  end

  describe "OP-14 partition DDL helpers" do
    @plan "SELECT step, sql_text FROM relay_private.partitioned_index_plan($1, $2, $3) ORDER BY step"
    @create ~r/^CREATE INDEX CONCURRENTLY IF NOT EXISTS (dead_letters_p\d{6})_test_index ON relay\.\1 \(tenant_id, created_at\)$/
    @attach ~r/^ALTER INDEX relay\.dead_letters_test_index ATTACH PARTITION relay\.dead_letters_p\d{6}_test_index$/

    test "OP-14: the partitioned index plan creates the parent shell, a concurrent index per leaf and the attachments" do
      committed(fn ->
        args = ["dead_letters", "dead_letters_test_index", "(tenant_id, created_at)"]
        [[1, first] | rest] = maint_rows!(@plan, args)

        assert first ==
                 "CREATE INDEX IF NOT EXISTS dead_letters_test_index ON ONLY relay.dead_letters (tenant_id, created_at)"

        assert rest != []

        for [[_, create], [_, attach]] <- Enum.chunk_every(rest, 2) do
          assert create =~ @create
          assert attach =~ @attach
        end

        assert {:error, %Postgrex.Error{}} =
                 MaintRepo.query(@plan, ["dead_letters", "x", "(id); DROP TABLE x"])
      end)
    end
  end
end
