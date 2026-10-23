defmodule Relay.Schema.SchemaIntegrityTest do
  use Relay.SqlCase, async: false

  @pending_size_checks [{"datasets", "json_schema"}, {"singleton_tasks", "state"}]

  defp tenant_tables do
    rows("""
    SELECT c.relname::text FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
    WHERE n.nspname = 'relay' AND c.relkind IN ('r', 'p')
    ORDER BY 1
    """)
    |> List.flatten()
  end

  setup do
    admin = connect(:admin)
    on_exit(fn -> Process.exit(admin, :normal) end)
    %{admin: admin}
  end

  defp reference_check do
    for [check, table, n] <- rows("SELECT * FROM relay_ops.reference_check()"),
        into: %{},
        do: {{check, table}, n}
  end

  defp orphan_check do
    for [check, table, n] <- rows("SELECT * FROM relay_ops.orphan_check()"),
        into: %{},
        do: {{check, table}, n}
  end

  defp delta(before, after_, key), do: Map.get(after_, key, 0) - Map.get(before, key, 0)

  describe "INV-36 tenant context" do
    test "INV-36: every tenant table forces row level security and the application roles cannot bypass it" do
      for table <- tenant_tables() do
        assert [[true, true]] =
                 rows(
                   "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = format('relay.%I', $1::text)::regclass",
                   [table]
                 ),
               table
      end

      for role <- ["relay_api", "relay_worker", "relay_app"] do
        assert [[false, false]] =
                 rows("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = $1", [role]),
               role

        assert [[0]] =
                 rows(
                   """
                   SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname LIKE 'relay%' AND pg_has_role($1, c.relowner, 'USAGE')
                   """,
                   [role]
                 ),
               "#{role} owns a table"
      end
    end

    test "INV-36: the tenant context lives only in its transaction and a query without it fails",
         %{admin: admin} do
      worker = connect("relay_worker")
      tenant = committed(admin, fn -> tenant!() end)

      committed(worker, fn ->
        assert ctx(tenant, "live") == "active"
        assert rows("SELECT count(*) FROM relay.recipients") == [[0]]
      end)

      assert {:error, %Postgrex.Error{postgres: %{code: code}}} =
               Postgrex.query(worker, "SELECT count(*) FROM relay.recipients", [])

      assert code in [:undefined_object, :invalid_text_representation]
      GenServer.stop(worker)
    end
  end

  describe "INV-37 cross-tenant links" do
    test "INV-37: a record of one tenant cannot reference a record of another tenant or environment",
         %{admin: admin} do
      rolled_back(admin, fn ->
        a = tenant!()
        b = tenant!()
        subtenant = id()

        rows(
          """
          INSERT INTO relay.subtenants (tenant_id, environment, id, access_organization_id, name,
            state, created_at, updated_at)
          VALUES ($1, 'live', $2, 'org-inv37', 'INV-37', 'active', now(), now())
          """,
          [a, subtenant]
        )

        insert = """
        INSERT INTO relay.settings (tenant_id, environment, id, subtenant_id, key, value,
          created_at, updated_at)
        VALUES ($1, $2, $3, $4, 'inv37.link', NULL, now(), now())
        """

        assert sql_error(insert, [b, "live", id(), subtenant]).postgres.code ==
                 :foreign_key_violation

        assert sql_error(insert, [a, "test", id(), subtenant]).postgres.code ==
                 :foreign_key_violation

        assert rows(insert, [a, "live", id(), subtenant]) == []
      end)
    end

    test "INV-37: tenant_id and environment are never null and every uniqueness is scoped by tenant" do
      for table <- tenant_tables() do
        assert rows(
                 """
                 SELECT a.attname::text FROM pg_attribute a
                 WHERE a.attrelid = format('relay.%I', $1::text)::regclass
                   AND a.attname IN ('tenant_id', 'environment') AND NOT a.attnotnull
                 """,
                 [table]
               ) == [],
               table
      end

      unscoped =
        rows("""
        SELECT c.relname::text, i.relname::text
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class c ON c.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute t ON t.attrelid = c.oid AND t.attname = 'tenant_id'
        WHERE n.nspname = 'relay' AND x.indisunique AND NOT c.relispartition
          AND x.indkey[0] <> t.attnum
        ORDER BY 1, 2
        """)

      assert unscoped == []
    end

    test "INV-37: the nightly check finds no row without a tenant and no row of a missing tenant",
         %{admin: admin} do
      found = on(admin, &orphan_check/0)

      for {{check, table}, n} <- found,
          check in ["null_scope", "tenant_missing"],
          do: assert(n == 0, "#{check} #{table}")
    end
  end

  describe "OP-42 reference check" do
    test "OP-42: every expected foreign key is in place and validated and none is unlisted",
         %{admin: admin} do
      found = on(admin, &reference_check/0)

      for {{check, table}, n} <- found,
          String.starts_with?(check, "fk_"),
          do: assert(n == 0, "#{check} #{table}")

      assert Map.has_key?(found, {"fk_missing", "deliveries"})
      assert Map.has_key?(found, {"stream_head_missing", "outbox_events"})
    end

    test "TN-12: a dropped, unvalidated or unlisted foreign key is reported", %{admin: admin} do
      rolled_back(admin, fn ->
        before = reference_check()
        rows("ALTER TABLE relay.settings DROP CONSTRAINT settings_subtenant_id_fkey")
        assert delta(before, reference_check(), {"fk_missing", "settings"}) == 1

        rows("""
        ALTER TABLE relay.settings ADD CONSTRAINT settings_subtenant_id_fkey
          FOREIGN KEY (tenant_id, environment, subtenant_id)
          REFERENCES relay.subtenants (tenant_id, environment, id) NOT VALID
        """)

        found = reference_check()
        assert delta(before, found, {"fk_missing", "settings"}) == 0
        assert delta(before, found, {"fk_not_validated", "settings"}) == 1

        rows("""
        ALTER TABLE relay.legal_holds ADD CONSTRAINT legal_holds_extra_fkey
          FOREIGN KEY (tenant_id, environment, recipient_id)
          REFERENCES relay.recipients (tenant_id, environment, id)
        """)

        assert delta(before, reference_check(), {"fk_unlisted", "legal_holds"}) == 1
      end)
    end

    test "OP-42: an outbox event that its stream head does not cover is reported", %{admin: admin} do
      rolled_back(admin, fn ->
        tenant = tenant!()
        before = reference_check()

        insert = """
        INSERT INTO relay.outbox_events (tenant_id, environment, id, created_at, event_type,
          stream_key, epoch, seq, payload, state)
        VALUES ($1, 'live', $2, now(), 'test.recorded', $3, 1, $4, '{}', 'pending')
        """

        rows(insert, [tenant, id(), "test:op42-orphan", 1])
        assert delta(before, reference_check(), {"stream_head_missing", "outbox_events"}) == 1

        rows(
          "INSERT INTO relay.stream_heads (tenant_id, environment, stream_key, epoch, last_seq, updated_at) VALUES ($1, 'live', $2, 1, 1, now())",
          [tenant, "test:op42-orphan"]
        )

        assert delta(before, reference_check(), {"stream_head_missing", "outbox_events"}) == 0
        rows(insert, [tenant, id(), "test:op42-orphan", 2])
        assert delta(before, reference_check(), {"stream_head_missing", "outbox_events"}) == 1
      end)
    end

    test "OP-42: seeded orphans are each counted exactly once", %{admin: admin} do
      rolled_back(admin, fn ->
        before = orphan_check()
        rows("SET LOCAL session_replication_role = replica")
        missing_tenant = id()

        rows(
          """
          INSERT INTO relay.subtenants (tenant_id, environment, id, access_organization_id, name,
            state, created_at, updated_at)
          VALUES ($1, 'live', $2, 'org-op42', 'OP-42', 'active', now(), now())
          """,
          [missing_tenant, id()]
        )

        rows("SET LOCAL session_replication_role = origin")
        found = orphan_check()
        assert delta(before, found, {"tenant_missing", "subtenants"}) == 1

        for {key, n} <- found,
            key != {"tenant_missing", "subtenants"},
            do: assert(n == Map.get(before, key, 0), inspect(key))
      end)
    end
  end

  describe "OP-57 OP-1 schema health" do
    test "OP-57: no index is invalid or unready" do
      assert rows("""
             SELECT c.relname::text FROM pg_index x
             JOIN pg_class c ON c.oid = x.indexrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname LIKE 'relay%' AND (NOT x.indisvalid OR NOT x.indisready)
             """) == []
    end

    test "OP-57: every CHECK and foreign key constraint is validated" do
      assert rows("""
             SELECT c.relname::text, k.conname::text FROM pg_constraint k
             JOIN pg_class c ON c.oid = k.conrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname LIKE 'relay%' AND k.contype IN ('c', 'f') AND NOT k.convalidated
             """) == []
    end

    test "OP-1: every jsonb column has a size CHECK" do
      unchecked =
        rows("""
        SELECT c.relname::text, a.attname::text
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'relay' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
          AND a.attnum > 0 AND NOT a.attisdropped AND a.atttypid = 'jsonb'::regtype
          AND NOT EXISTS (
            SELECT 1 FROM pg_constraint k
            WHERE k.conrelid = c.oid AND k.contype = 'c' AND k.convalidated
              AND a.attnum = ANY (k.conkey)
              AND pg_get_constraintdef(k.oid) ~ ('pg_column_size\\(' || a.attname || '\\) <= [0-9]+'))
        ORDER BY 1, 2
        """)

      assert Enum.map(unchecked, &List.to_tuple/1) == @pending_size_checks
    end
  end

  describe "T-12 singleton tasks" do
    test "T-12: relay.singleton_tasks keeps one lease per task whose fencing token only grows", %{
      admin: admin
    } do
      rolled_back(admin, fn ->
        name = "integrity_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
        acquire = "SELECT result, fencing_token FROM relay_ops.singleton_acquire($1, $2, $3)"
        save = "SELECT relay_ops.singleton_save($1, $2, $3)"
        ttl = %Postgrex.Interval{secs: 30}

        assert [["acquired", 1]] = rows(acquire, [name, "node-a", ttl])
        assert [["renewed", 1]] = rows(acquire, [name, "node-a", ttl])
        assert [["held_by_other", nil]] = rows(acquire, [name, "node-b", ttl])
        assert one(save, [name, 1, %{"step" => 1}]) == "saved"

        rows("UPDATE relay.singleton_tasks SET lease_until = now() WHERE name = $1", [name])
        assert [["acquired", 2]] = rows(acquire, [name, "node-b", ttl])
        assert one(save, [name, 1, %{"step" => 2}]) == "not_leader"
        assert one(save, [name, 2, %{"step" => 2}]) == "saved"

        assert [["node-b", 2, %{"step" => 2}]] =
                 rows(
                   "SELECT leader_node, fencing_token, state FROM relay.singleton_tasks WHERE name = $1",
                   [name]
                 )

        assert rows("""
               SELECT name FROM relay.singleton_tasks
               WHERE fencing_token < 1 OR (leader_node IS NULL) <> (lease_until IS NULL)
               """) == []

        assert sql_error(
                 "INSERT INTO relay.singleton_tasks (name, fencing_token, updated_at) VALUES ($1, 1, now())",
                 [name]
               ).postgres.code == :unique_violation
      end)
    end
  end
end
