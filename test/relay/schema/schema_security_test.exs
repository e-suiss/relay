defmodule Relay.Schema.SchemaSecurityTest do
  use Relay.DataCase, async: true

  alias Relay.Repo

  @schemas ["relay", "relay_fn", "relay_ops", "relay_private"]
  @installation_tables ~w(audit_checkpoint_publications audit_checkpoints audit_leaves datasets
                          installation load_shed_events partition_policies schema_migrations
                          singleton_tasks)
  @append_only ~w(audit_checkpoint_publications audit_checkpoints audit_leaves audit_log
                  dataset_versions delivery_events erasure_log load_shed_events usage_records)
  @shared_read ~w(dataset_active dataset_versions)
  @partitioned %{
    "audit_log" => "created_at",
    "dead_letters" => "created_at",
    "delivery_attempts" => "created_at",
    "delivery_events" => "received_at",
    "idempotency_keys" => "created_at",
    "outbox_events" => "created_at",
    "usage_records" => "usage_day"
  }
  @small_integers [
    {"dead_letters", "replay_depth"},
    {"deliveries", "delivery_rank"},
    {"deliveries", "replay_depth"},
    {"idempotency_keys", "response_status"}
  ]
  @later_stage_references [
    {"dead_letters", "provider_account_id"},
    {"deliveries", "pause_kill_switch_id"},
    {"deliveries", "provider_account_id"},
    {"deliveries", "target_id"},
    {"delivery_attempts", "provider_account_id"},
    {"delivery_events", "evidence_version_id"},
    {"webhook_receipts", "provider_account_id"}
  ]
  @roles ~w(relay_owner relay_app relay_api relay_worker relay_queue relay_maint relay_archive
            relay_report)

  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp relations do
    rows("""
    SELECT c.relname::text, c.relkind::text, c.relispartition, c.relrowsecurity,
      c.relforcerowsecurity, coalesce(parent.relname::text, c.relname::text)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
    LEFT JOIN pg_class parent ON parent.oid = i.inhparent
    WHERE n.nspname = 'relay' AND c.relkind IN ('r', 'p')
    """)
    |> Enum.map(fn [name, kind, leaf?, rls?, force?, parent] ->
      %{name: name, kind: kind, leaf?: leaf?, rls?: rls?, force?: force?, parent: parent}
    end)
  end

  defp columns do
    rows("""
    SELECT c.relname::text, a.attname::text
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'relay' AND c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped
    """)
    |> Enum.group_by(&hd/1, &List.last/1)
  end

  defp tenant_tables do
    cols = columns()
    for rel <- relations(), "tenant_id" in Map.get(cols, rel.name, []), do: rel
  end

  defp key_columns(kind) do
    rows(
      """
      SELECT c.relname::text, con.conname::text,
        ARRAY(SELECT a.attname::text FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum ORDER BY k.ord),
        coalesce(r.relname::text, ''),
        ARRAY(SELECT a.attname::text FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum ORDER BY k.ord)
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_class r ON r.oid = con.confrelid
      WHERE n.nspname = 'relay' AND con.contype::text = $1 AND con.conparentid = 0
      """,
      [kind]
    )
  end

  defp unique_indexes do
    rows("""
    SELECT c.relname::text, i.relname::text,
      ARRAY(SELECT a.attname::text FROM unnest(x.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = k.attnum ORDER BY k.ord)
    FROM pg_index x
    JOIN pg_class i ON i.oid = x.indexrelid
    JOIN pg_class c ON c.oid = x.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'relay' AND x.indisunique AND NOT c.relispartition
    """)
  end

  defp policies do
    rows("""
    SELECT c.relname::text, p.polname::text, p.polcmd::text, p.polpermissive, p.polroles::oid[],
      pg_get_expr(p.polqual, p.polrelid), pg_get_expr(p.polwithcheck, p.polrelid)
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'relay'
    """)
    |> Enum.group_by(&hd/1)
  end

  defp granted(tables, privileges) do
    rows(
      """
      SELECT t, r, p FROM unnest($1::text[]) AS t, unnest($2::text[]) AS r, unnest($3::text[]) AS p
      WHERE has_table_privilege(r::name, format('relay.%I', t)::regclass::oid, p)
      """,
      [tables, @roles, privileges]
    )
  end

  defp catalog(name), do: "conformance/catalog/#{name}" |> File.read!() |> Jason.decode!()

  describe "TN-12 T-60 scope columns and keys" do
    test "TN-12: every tenant table and partition has a primary key led by tenant_id and environment" do
      pks = key_columns("p") |> Map.new(fn [table, _, cols, _, _] -> {table, cols} end)

      leaf_pks =
        rows("""
        SELECT c.relname::text, ARRAY(SELECT a.attname::text FROM unnest(con.conkey) WITH ORDINALITY
          AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
          ORDER BY k.ord)
        FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'relay' AND con.contype = 'p' AND c.relispartition
        """)
        |> Map.new(fn [table, cols] -> {table, cols} end)

      all_pks = Map.merge(pks, leaf_pks)

      for rel <- tenant_tables() do
        assert ["tenant_id", "environment" | _] = Map.fetch!(all_pks, rel.name), rel.name
      end

      assert Map.fetch!(pks, "tenants") == ["id"]
    end

    test "T-60: partitioned tables carry the partition key in their primary key" do
      pks = key_columns("p") |> Map.new(fn [table, _, cols, _, _] -> {table, cols} end)

      for {table, key} <- @partitioned do
        assert Map.fetch!(pks, table) == ["tenant_id", "environment", "id", key]
      end
    end

    test "OP-68: every unique key of a tenant table is led by tenant_id and environment, except the Access tenant id" do
      tenant = MapSet.new(tenant_tables(), & &1.name)

      for [table, index, cols] <- unique_indexes(), MapSet.member?(tenant, table) do
        assert ["tenant_id", "environment" | _] = cols, "#{table}.#{index}"
      end

      tenant_uniques =
        for [table, index, cols] <- unique_indexes(), table == "tenants", do: {index, cols}

      assert Enum.sort(tenant_uniques) == [
               {"tenants_access_tenant_id_key", ["access_tenant_id"]},
               {"tenants_pkey", ["id"]}
             ]
    end

    test "TN-12: every foreign key of a tenant table is composite with tenant_id and environment" do
      tenant = MapSet.new(tenant_tables(), & &1.name)
      installation = MapSet.new(@installation_tables)

      for [table, name, cols, target, target_cols] <- key_columns("f"),
          MapSet.member?(tenant, table) do
        cond do
          target == "tenants" ->
            assert {cols, target_cols} == {["tenant_id"], ["id"]}, name

          MapSet.member?(installation, target) ->
            refute "tenant_id" in cols, name

          true ->
            assert ["tenant_id", "environment" | rest] = cols, name
            assert ["tenant_id", "environment" | _] = target_cols, name
            assert length(rest) == length(target_cols) - 2, name
        end
      end
    end

    test "TN-12: references without a foreign key are exactly the listed exceptions" do
      exceptions = catalog("fk-exceptions.json")
      cols = columns()

      covered =
        for [table, _, fk_cols, _, _] <- key_columns("f"),
            col <- fk_cols,
            into: MapSet.new(),
            do: {table, col}

      for %{"table" => table, "columns" => listed, "reason" => reason} = exception <- exceptions do
        assert is_binary(reason) and reason != ""
        assert exception["basis"] in ["structural", "measured"], table

        for col <- listed do
          assert col in Map.fetch!(cols, table), "#{table}.#{col}"
          refute MapSet.member?(covered, {table, col}), "#{table}.#{col} has a foreign key"
        end
      end

      excepted =
        for %{"table" => t, "columns" => cs} <- exceptions,
            c <- cs,
            into: MapSet.new(),
            do: {t, c}

      uuid_refs =
        rows("""
        SELECT c.relname::text, a.attname::text
        FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'relay' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
          AND a.attnum > 0 AND NOT a.attisdropped AND a.atttypid = 'uuid'::regtype
          AND (a.attname LIKE '%\\_id' OR a.attname = 'fallback_of') AND a.attname <> 'tenant_id'
        """)

      for [table, col] <- uuid_refs do
        assert MapSet.member?(covered, {table, col}) or MapSet.member?(excepted, {table, col}) or
                 {table, col} in @later_stage_references,
               "#{table}.#{col} has no foreign key and is not listed"
      end
    end

    test "TN-11: Relay keeps one record schema for every tenant" do
      schemas =
        rows("SELECT nspname::text FROM pg_namespace WHERE nspname LIKE 'relay%' ORDER BY 1")

      assert List.flatten(schemas) == [
               "relay",
               "relay_fn",
               "relay_ops",
               "relay_private",
               "relay_queue"
             ]

      outside =
        rows("""
        SELECT n.nspname::text, c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('relay_fn', 'relay_ops', 'relay_private', 'public') AND c.relkind IN ('r', 'p')
        """)

      assert outside == []
    end

    test "TN-12: tables without tenant_id are the installation tables and the root tenant table" do
      cols = columns()

      without =
        for rel <- relations(),
            not rel.leaf?,
            "tenant_id" not in Map.fetch!(cols, rel.name),
            do: rel.name

      assert Enum.sort(without) == Enum.sort(["tenants" | @installation_tables])
    end
  end

  describe "TN-13 TN-16 row level security" do
    test "TN-16: every tenant table and every partition has row level security enabled and forced" do
      for rel <- [Enum.find(relations(), &(&1.name == "tenants")) | tenant_tables()] do
        assert rel.rls? and rel.force?, rel.name
      end
    end

    test "TN-13: every tenant table has one policy for every command and role, without missing_ok" do
      policies = policies()

      for rel <- [%{name: "tenants"} | tenant_tables()] do
        assert [[_, name, "*", true, [0], using, check]] = Map.fetch!(policies, rel.name),
               rel.name

        assert name == "#{rel.name}_scope"
        refute using =~ ~r/current_setting\('relay\.[a-z_]+'::text,/
        refute check =~ ~r/current_setting\('relay\.[a-z_]+'::text,/
      end
    end

    test "OP-68: tenant policies bind both tenant_id and environment and are the same template everywhere" do
      policies = policies()
      [[_, _, _, _, _, template, template_check]] = Map.fetch!(policies, "subtenants")

      assert template == template_check
      assert template =~ "current_setting('relay.tenant_id'::text)"
      assert template =~ "current_setting('relay.environment'::text)"
      assert template =~ ~r/::(relay\.)?environment\b/

      for rel <- tenant_tables(), rel.parent not in @shared_read do
        [[_, _, _, _, _, using, check]] = Map.fetch!(policies, rel.name)
        assert {using, check} == {template, template}, rel.name
      end

      for table <- @shared_read do
        [[_, _, _, _, _, using, check]] = Map.fetch!(policies, table)
        assert check == template
        assert using =~ "relay_private.installation_tenant_id()"
        assert using =~ "IS NOT NULL"
      end

      [[_, _, _, _, _, tenants_using, tenants_check]] = Map.fetch!(policies, "tenants")
      assert tenants_using == tenants_check
      assert tenants_using =~ "(id = ( SELECT (current_setting('relay.tenant_id'::text))::uuid"
    end
  end

  describe "TN-13 queries without context" do
    @context_tables ["notifications", "tenants", "dataset_versions", "delivery_events"]

    @context_rows [
      """
      INSERT INTO relay.tenants (id, kind, access_tenant_id, region, default_timezone,
        default_locale, status, status_changed_at, created_at, updated_at)
      VALUES (uuidv7(), 'tenant', 'context-test:' || uuidv7(), 'tr', 'Europe/Istanbul', 'tr',
        'active', now(), now(), now())
      """,
      """
      INSERT INTO relay.dataset_versions (tenant_id, environment, id, dataset_name, version_no,
        content, content_digest, source, source_ref, valid_from, published_by_ref, created_at)
      VALUES (uuidv7(), 'live', uuidv7(), 'context_test', 1, '{}', pg_catalog.sha256('\\x00'::bytea), 'operator',
        'context-test', now(), 'context-test', now())
      """,
      """
      INSERT INTO relay.notifications (tenant_id, environment, id, recipient_id, dedup_key,
        message_class, sender_type, is_test, state, duplicate_count, created_at, updated_at)
      VALUES (uuidv7(), 'live', uuidv7(), uuidv7(), 'context-test', 'transactional', 'system',
        false, 'active', 0, now(), now())
      """,
      """
      INSERT INTO relay.delivery_events (tenant_id, environment, id, received_at, delivery_id,
        actor, event_type, occurred_at, projection_result, detail)
      SELECT uuidv7(), 'live', uuidv7(), b.at, uuidv7(), 'relay', 'delivery.queued', b.at,
        'applied', '{}'
      FROM (SELECT (regexp_match(pg_get_expr(c.relpartbound, c.oid), '''([^'']+)'''))[1]::timestamptz
                + interval '1 hour' AS at
            FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
            WHERE i.inhparent = 'relay.delivery_events'::regclass
              AND pg_get_expr(c.relpartbound, c.oid) <> 'DEFAULT'
            ORDER BY c.relname DESC LIMIT 1) b
      """
    ]

    defp seeded_as_worker(conn, fun) do
      Postgrex.transaction(conn, fn tx ->
        Postgrex.query!(tx, "SET LOCAL session_replication_role = replica", [])
        for sql <- @context_rows, do: Postgrex.query!(tx, sql, [])
        Postgrex.query!(tx, "SET LOCAL session_replication_role = origin", [])

        for table <- @context_tables do
          assert %{rows: [[true]]} =
                   Postgrex.query!(tx, "SELECT EXISTS (SELECT FROM relay.#{table})", []),
                 table
        end

        Postgrex.query!(tx, "SET LOCAL ROLE relay_worker", [])
        Postgrex.rollback(tx, fun.(tx))
      end)
    end

    defp select(tx, table),
      do: Postgrex.query(tx, "SELECT * FROM relay.#{table}", [], mode: :savepoint)

    # TN-69
    test "TN-13, TN-69: a query without tenant or environment context fails as soon as it reads a row" do
      {:ok, conn} = Postgrex.start_link(RelayDev.Database.connection(:admin))

      assert {:error, {missing, missing_environment, results}} =
               seeded_as_worker(conn, fn tx ->
                 missing = Enum.map(@context_tables, &select(tx, &1))

                 Postgrex.query!(tx, "SELECT set_config('relay.tenant_id', $1, true)", [
                   Ecto.UUID.generate()
                 ])

                 missing_environment = select(tx, "notifications")
                 Postgrex.query!(tx, "SELECT set_config('relay.environment', 'test', true)", [])
                 results = for table <- @context_tables, do: select(tx, table)
                 {missing, missing_environment, results}
               end)

      for {table, result} <- Enum.zip(@context_tables, missing) do
        assert {:error, %Postgrex.Error{postgres: %{code: :undefined_object}}} = result, table
      end

      assert {:error, %Postgrex.Error{postgres: %{code: :undefined_object}}} = missing_environment
      assert Enum.map(results, fn {:ok, result} -> result.rows end) == [[], [], [], []]

      assert {:error, {:error, %Postgrex.Error{postgres: %{code: :invalid_text_representation}}}} =
               seeded_as_worker(conn, &select(&1, "notifications"))

      GenServer.stop(conn)
    end
  end

  describe "INV-6 INV-49 append-only tables" do
    test "INV-6: append-only tables and their partitions reject UPDATE, DELETE and TRUNCATE with triggers" do
      triggers =
        rows("""
        SELECT c.relname::text, t.tgtype::integer, p.proname::text
        FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE n.nspname = 'relay' AND NOT t.tgisinternal
        """)
        |> Enum.group_by(&hd/1, fn [_, type, fun] -> {type, fun} end)

      for rel <- relations(), rel.parent in @append_only do
        found = Map.get(triggers, rel.name, [])

        assert Enum.any?(found, fn {type, fun} ->
                 fun == "reject_mutation" and Bitwise.band(type, 1 + 2 + 8 + 16) == 27
               end),
               "#{rel.name}: row trigger"

        assert Enum.any?(found, fn {type, fun} ->
                 fun == "reject_mutation" and Bitwise.band(type, 2 + 32) == 34 and
                   Bitwise.band(type, 1) == 0
               end),
               "#{rel.name}: truncate trigger"
      end
    end

    test "INV-49: no role holds UPDATE, DELETE or TRUNCATE on an append-only table" do
      append_only = for rel <- relations(), rel.parent in @append_only, do: rel.name
      assert granted(append_only, ~w(UPDATE DELETE TRUNCATE)) == []
    end

    test "OP-9: no role holds DELETE or TRUNCATE on any record table" do
      assert granted(Enum.map(relations(), & &1.name), ~w(DELETE TRUNCATE)) == []
    end

    test "INV-6: the append-only triggers stop the table owner too" do
      {:ok, conn} = Postgrex.start_link(RelayDev.Database.connection("relay_migrator"))

      for statement <- [
            "UPDATE relay.usage_records SET quantity = 2",
            "DELETE FROM relay.usage_records",
            "TRUNCATE relay.usage_records"
          ] do
        result =
          Postgrex.transaction(conn, fn tx ->
            tenant = Ecto.UUID.generate()
            Postgrex.query!(tx, "SELECT set_config('relay.tenant_id', $1, true)", [tenant])
            Postgrex.query!(tx, "SELECT set_config('relay.environment', 'live', true)", [])

            Postgrex.query!(
              tx,
              """
              INSERT INTO relay.usage_records (tenant_id, environment, id, usage_day, channel, provider,
                outcome, is_test, quantity, attempt_count, created_at)
              VALUES ($1::text::uuid, 'live', uuidv7(), current_date, 'sms', 'test', 'accepted', false, 1, 1, now())
              """,
              [tenant]
            )

            case Postgrex.query(tx, statement, []) do
              {:error, error} -> Postgrex.rollback(tx, error)
              {:ok, _} -> Postgrex.rollback(tx, :not_rejected)
            end
          end)

        assert {:error, %Postgrex.Error{postgres: %{message: "invariant_violation"}}} = result,
               statement
      end

      GenServer.stop(conn)
    end
  end

  describe "OP-8 functions" do
    test "OP-8: every SECURITY DEFINER function pins search_path and TimeZone and has the expected owner" do
      owners = %{
        "relay_fn" => "relay_owner",
        "relay_ops" => "relay_maint",
        "relay_private" => "relay_migrator"
      }

      definers =
        rows(
          """
          SELECT n.nspname::text, p.oid::regprocedure::text, pg_get_userbyid(p.proowner)::text,
            coalesce(p.proconfig, '{}')
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname::text = ANY($1::text[]) AND p.prosecdef
          """,
          [@schemas]
        )

      assert definers != []

      for [schema, fun, owner, config] <- definers do
        assert owner == Map.fetch!(owners, schema), fun
        assert "search_path=pg_catalog, pg_temp" in config, fun
        assert "TimeZone=UTC" in config, fun
      end
    end

    test "OP-8: no function in a Relay schema is executable by PUBLIC" do
      public =
        rows(
          """
          SELECT p.oid::regprocedure::text
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname::text = ANY($1::text[])
            AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0))
          """,
          [@schemas ++ ["relay_queue"]]
        )

      assert public == []
    end

    test "OP-8: only relay_ops functions run as a role that bypasses row level security" do
      bypassing =
        rows(
          """
          SELECT n.nspname::text, p.oid::regprocedure::text
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          JOIN pg_roles r ON r.oid = p.proowner
          WHERE n.nspname::text = ANY($1::text[]) AND p.prosecdef AND (r.rolbypassrls OR r.rolsuper)
          """,
          [@schemas]
        )

      assert Enum.all?(bypassing, fn [schema, _] -> schema == "relay_ops" end)
    end

    test "T-10: no function or trigger in the database uses LISTEN or NOTIFY" do
      notifying =
        rows("""
        SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname LIKE 'relay%' AND p.prosrc ~* '(pg_notify|\\mnotify\\M|\\mlisten\\M)'
        """)

      assert notifying == []
    end

    test "WF-47: no function in a Relay schema converts time zones" do
      converting =
        rows("""
        SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname LIKE 'relay%' AND p.prosrc ~* 'at\\s+time\\s+zone'
        """)

      assert converting == []
    end
  end

  describe "OP-1 C-57 types" do
    test "OP-1: Relay schemas use no enum, json, citext, timestamp without time zone or floating point type" do
      enums =
        rows(
          """
          SELECT t.typname::text FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
          WHERE n.nspname::text = ANY($1::text[]) AND t.typtype = 'e'
          """,
          [@schemas]
        )

      assert enums == []

      forbidden =
        rows(
          """
          SELECT c.relname::text, a.attname::text, format_type(coalesce(nullif(t.typbasetype, 0), a.atttypid), NULL)
          FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_type t ON t.oid = a.atttypid
          WHERE n.nspname::text = ANY($1::text[]) AND c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped
            AND c.relname <> 'schema_migrations'
            AND format_type(coalesce(nullif(t.typbasetype, 0), a.atttypid), NULL) IN
              ('json', 'citext', 'timestamp without time zone', 'real', 'double precision')
          """,
          [@schemas]
        )

      assert forbidden == []
    end

    test "OP-1: integers are bigint except the listed small integers" do
      small =
        rows(
          """
          SELECT c.relname::text, a.attname::text, format_type(a.atttypid, NULL)
          FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname::text = ANY($1::text[]) AND c.relkind IN ('r', 'p') AND NOT c.relispartition
            AND a.attnum > 0 AND NOT a.attisdropped AND a.atttypid IN ('smallint'::regtype, 'integer'::regtype)
          """,
          [@schemas]
        )

      assert Enum.sort(for [t, c, "smallint"] <- small, do: {t, c}) == Enum.sort(@small_integers)
      assert length(small) == length(@small_integers)
    end

    test "C-57: tenants require a time zone and a locale; no column stores local time" do
      required =
        rows("""
        SELECT a.attname::text, a.attnotnull FROM pg_attribute a
        WHERE a.attrelid = 'relay.tenants'::regclass AND a.attname IN ('default_timezone', 'default_locale')
        ORDER BY 1
        """)

      assert required == [["default_locale", true], ["default_timezone", true]]
    end
  end

  describe "OP-13 OP-66 partitions" do
    test "OP-13: partitioned tables have no default partition and match the partition policies" do
      partitioned =
        rows("""
        SELECT c.relname::text, pt.partdefid::integer, a.attname::text
        FROM pg_partitioned_table pt JOIN pg_class c ON c.oid = pt.partrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
        WHERE n.nspname = 'relay'
        """)

      assert Map.new(partitioned, fn [t, _, key] -> {t, key} end) == @partitioned
      assert Enum.all?(partitioned, fn [_, default, _] -> default == 0 end)

      policies = rows("SELECT table_name FROM relay.partition_policies ORDER BY 1")
      assert List.flatten(policies) == @partitioned |> Map.keys() |> Enum.sort()
    end

    test "OP-66: the partition policies carry the initial intervals, horizons and hot retention" do
      seeded =
        rows("""
        SELECT table_name, partition_interval, premake_horizon::text, alarm_threshold::text,
          hot_retention::text
        FROM relay.partition_policies ORDER BY table_name
        """)

      daily = ["day", "14 days", "3 days", "90 days"]
      monthly = ["month", "2 mons", "3 days", "1 year 1 mon"]

      assert seeded == [
               ["audit_log" | monthly],
               ["dead_letters" | monthly],
               ["delivery_attempts" | daily],
               ["delivery_events" | daily],
               ["idempotency_keys" | daily],
               ["outbox_events" | monthly],
               ["usage_records" | monthly]
             ]
    end

    test "OP-13: every partitioned table has partitions from today up to its premake horizon" do
      leaves = MapSet.new(relations(), & &1.name)
      today = Date.utc_today()
      daily = ~w(delivery_attempts delivery_events idempotency_keys)

      for {table, _} <- @partitioned do
        expected =
          if table in daily,
            do: for(days <- 0..14, do: Date.add(today, days) |> Calendar.strftime("%Y%m%d")),
            else:
              for(
                months <- 0..2,
                do:
                  today
                  |> Date.beginning_of_month()
                  |> Date.shift(month: months)
                  |> Calendar.strftime("%Y%m")
              )

        for suffix <- expected,
            do: assert(MapSet.member?(leaves, "#{table}_p#{suffix}"), "#{table}_p#{suffix}")
      end
    end

    test "T-60: tables whose uniqueness does not depend on time are not partitioned" do
      kinds =
        rows("""
        SELECT c.relname::text, c.relkind::text FROM pg_class c
        WHERE c.oid IN ('relay.notifications'::regclass, 'relay.deliveries'::regclass,
                        'relay.webhook_receipts'::regclass)
        ORDER BY 1
        """)

      assert kinds == [["deliveries", "r"], ["notifications", "r"], ["webhook_receipts", "r"]]
    end
  end

  describe "OP-25 TN-16 erasure scope" do
    test "OP-25: every table with tenant_id or a personal column is in the erasure scope list" do
      scope = Map.new(catalog("erasure-scope.json")["tables"], &{&1["table"], &1})
      cols = columns()

      for {table, table_cols} <- cols, not String.match?(table, ~r/_p\d{6,8}$/) do
        personal = Enum.filter(table_cols, &String.match?(&1, ~r/_(ct|bidx|bidx_next)$/))

        if "tenant_id" in table_cols or personal != [] do
          assert %{
                   "personal_columns" => listed,
                   "tenant_close" => close,
                   "subject_erasure" => erase
                 } =
                   Map.get(scope, table),
                 "#{table} is missing from erasure-scope.json"

          assert Enum.sort(listed) == Enum.sort(personal), table
          assert is_binary(close) and close != ""
          assert is_binary(erase) and erase != ""
        end
      end

      for table <- Map.keys(scope), do: assert(Map.has_key?(cols, table), table)
    end
  end

  describe "TN-13 OP-10 settings" do
    test "TN-13: no role or database setting presets the tenant context or relaxes synchronous commit" do
      settings =
        rows("""
        SELECT c FROM pg_db_role_setting s, unnest(s.setconfig) AS c
        WHERE c LIKE 'relay.%' OR (c LIKE 'synchronous\\_commit=%' AND c <> 'synchronous_commit=on')
        """)

      assert settings == []
    end

    test "OP-11: role timeouts and search paths are those of the role table" do
      expected = %{
        "relay_api" => ["5s", "2s", "10s", "10s", "relay, pg_catalog"],
        "relay_worker" => ["30s", "2s", "10s", "60s", "relay, pg_catalog"],
        "relay_report" => ["5min", "2s", "60s", "10min", "relay, pg_catalog"],
        "relay_queue" => ["60s", "2s", "10s", "120s", "relay_queue, pg_catalog"],
        "relay_maint" => ["60s", "2s", "60s", "15min", "relay, pg_catalog"],
        "relay_archive" => ["15min", "2s", "60s", "60min", "relay, pg_catalog"],
        "relay_migrator" => ["0", "3s", "60s", "0", "relay, pg_catalog"]
      }

      keys =
        ~w(statement_timeout lock_timeout idle_in_transaction_session_timeout transaction_timeout search_path)

      for {role, values} <- expected do
        [[config]] =
          rows(
            "SELECT s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = $1 AND s.setdatabase = 0",
            [role]
          )

        settings = Map.new(config, &(&1 |> String.split("=", parts: 2) |> List.to_tuple()))
        assert Enum.map(keys, &Map.get(settings, &1)) == values, role
        assert map_size(settings) == length(keys), role
      end
    end
  end

  describe "TN-33 TN-3 T-17 C-85 C-3 WF-1 schema shape" do
    test "TN-33: pgcrypto is not installed" do
      assert rows("SELECT extname::text FROM pg_extension WHERE extname = 'pgcrypto'") == []
    end

    test "TN-3: subtenants have no parent subtenant column" do
      refute Enum.any?(Map.fetch!(columns(), "subtenants"), &String.contains?(&1, "parent"))
    end

    test "OP-68: the job queue lives in relay_queue and there is no oban schema" do
      assert rows("SELECT 1 FROM pg_namespace WHERE nspname = 'oban'") == []

      tables =
        rows(
          "SELECT n.nspname::text, c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname LIKE 'oban\\_%' AND c.relkind IN ('r', 'p') ORDER BY 2"
        )

      assert tables == [["relay_queue", "oban_jobs"], ["relay_queue", "oban_peers"]]
    end

    test "OP-68: the retention class domain is the set of Relay.RetentionClass codes" do
      [[definition]] =
        rows("""
        SELECT pg_get_constraintdef(con.oid) FROM pg_constraint con
        JOIN pg_type t ON t.oid = con.contypid JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'relay' AND t.typname = 'retention_class'
        """)

      codes = for [_, code] <- Regex.scan(~r/'([a-z_]+)'/, definition), do: code
      assert codes == Enum.map(Relay.RetentionClass.all(), &Relay.RetentionClass.dump/1)
    end

    test "C-3: deliveries hold no attempt state and attempts hold no channel or target" do
      cols = columns()
      refute "state" in Map.fetch!(cols, "deliveries")

      for col <- ~w(channel target_kind target_id target_key notification_id) do
        refute col in Map.fetch!(cols, "delivery_attempts")
      end
    end

    test "WF-1: notifications, deliveries and attempts form one foreign key chain" do
      fks = for [table, _, _, target, _] <- key_columns("f"), do: {table, target}

      assert {"deliveries", "notifications"} in fks
      assert {"delivery_attempts", "deliveries"} in fks
      assert {"delivery_events", "deliveries"} in fks
      assert {"notifications", "recipients"} in fks
    end
  end
end
