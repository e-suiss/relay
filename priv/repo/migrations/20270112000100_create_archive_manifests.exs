defmodule Relay.Repo.Migrations.CreateArchiveManifests do
  use Ecto.Migration

  @classes "ARRAY['audit', 'commercial_consent', 'commercial_message', 'delivery_record', 'dsr_log', 'erasure_log', 'traffic']::text[]"

  @functions [
    {"relay_private.archive_retain_days(text[])", []},
    {"relay_private.archive_leaves()", ~w(relay_archive)},
    {"relay_private.archive_leader(bigint)", []},
    {"relay_private.archive_begin(uuid, text, text, text, text, timestamp with time zone, bigint)",
     ~w(relay_archive)},
    {"relay_private.archive_verified(uuid, bigint, bytea, bigint, bigint)", ~w(relay_archive)},
    {"relay_private.archive_failed(uuid, text)", ~w(relay_archive)},
    {"relay_private.archive_drop(uuid, bigint)", ~w(relay_archive)},
    {"relay_private.restore_prepare(text, text)", ~w(relay_archive)},
    {"relay_private.staging_create(text, text, text)", ~w(relay_archive)},
    {"relay_private.staging_attach(text, text, text, timestamp with time zone, timestamp with time zone)",
     ~w(relay_archive)},
    {"relay_private.restore_seal(text, text, text)", ~w(relay_archive)},
    {"relay_private.partitioned_index_plan(text, text, text)", ~w(relay_maint)}
  ]

  # OP-15
  # OP-84
  # INV-47
  # DS-44
  # OP-14 (2, 6)
  # T-88
  def up do
    execute("""
    ALTER TABLE relay.partition_policies
      ADD COLUMN archive_retention_classes text[] NOT NULL DEFAULT '{}'
        CONSTRAINT partition_policies_archive_retention_classes_check
          CHECK (archive_retention_classes <@ #{@classes})
    """)

    execute("""
    UPDATE relay.partition_policies
      SET archive_retention_classes = ARRAY['delivery_record', 'commercial_message']
      WHERE table_name IN ('delivery_events', 'delivery_attempts')
    """)

    execute("""
    UPDATE relay.partition_policies SET archive_retention_classes = ARRAY['audit']
      WHERE table_name = 'audit_log'
    """)

    execute(~S"""
    CREATE TABLE relay.archive_manifests (
      id uuid NOT NULL,
      table_name text NOT NULL,
      leaf_name text NOT NULL
        CONSTRAINT archive_manifests_leaf_name_check CHECK (leaf_name ~ '^[a-z_][a-z0-9_]{0,62}$'),
      range_from timestamptz NOT NULL,
      range_to timestamptz NOT NULL,
      object_key text NOT NULL
        CONSTRAINT archive_manifests_object_key_check CHECK (char_length(object_key) <= 1024),
      schema_key text NOT NULL
        CONSTRAINT archive_manifests_schema_key_check CHECK (char_length(schema_key) <= 1024),
      migration_version bigint NOT NULL,
      retain_until timestamptz NOT NULL,
      status text NOT NULL
        CONSTRAINT archive_manifests_status_check
          CHECK (status IN ('started', 'verified', 'archived', 'failed')),
      row_count bigint CONSTRAINT archive_manifests_row_count_check CHECK (row_count >= 0),
      digest bytea CONSTRAINT archive_manifests_digest_check CHECK (octet_length(digest) = 32),
      file_bytes bigint CONSTRAINT archive_manifests_file_bytes_check CHECK (file_bytes >= 0),
      failure_code text
        CONSTRAINT archive_manifests_failure_code_check CHECK (char_length(failure_code) <= 64),
      fencing_token bigint NOT NULL,
      started_at timestamptz NOT NULL,
      verified_at timestamptz,
      archived_at timestamptz,
      failed_at timestamptz,
      CONSTRAINT archive_manifests_pkey PRIMARY KEY (id),
      CONSTRAINT archive_manifests_range_check CHECK (range_from < range_to),
      CONSTRAINT archive_manifests_verified_check CHECK (status NOT IN ('verified', 'archived')
        OR (row_count IS NOT NULL AND digest IS NOT NULL AND file_bytes IS NOT NULL
          AND verified_at IS NOT NULL)),
      CONSTRAINT archive_manifests_archived_check CHECK ((status = 'archived') = (archived_at IS NOT NULL)),
      CONSTRAINT archive_manifests_failed_check CHECK ((status = 'failed') = (failed_at IS NOT NULL))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX archive_manifests_archived_key ON relay.archive_manifests (table_name, leaf_name)
      WHERE status = 'archived'
    """)

    execute("""
    CREATE INDEX archive_manifests_leaf_index ON relay.archive_manifests (leaf_name, started_at)
    """)

    execute("""
    CREATE TRIGGER archive_manifests_no_delete BEFORE DELETE ON relay.archive_manifests
      FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute("""
    CREATE TRIGGER archive_manifests_no_truncate BEFORE TRUNCATE ON relay.archive_manifests
      FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()
    """)

    execute(
      "GRANT SELECT ON relay.archive_manifests TO relay_owner, relay_app, relay_maint, relay_archive"
    )

    Enum.each(functions(), &execute/1)

    for {signature, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
    end
  end

  def down, do: :ok

  defp functions do
    [
      ~S"""
      CREATE FUNCTION relay_private.archive_retain_days(p_classes text[]) RETURNS bigint
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_days bigint;
        v_found boolean;
        v_saved_tenant text;
        v_saved_environment text;
      BEGIN
        IF p_classes IS NULL OR cardinality(p_classes) = 0 THEN
          RETURN 0;
        END IF;
        SELECT s.setting INTO v_saved_tenant FROM pg_settings s WHERE s.name = 'relay.tenant_id';
        SELECT s.setting INTO v_saved_environment FROM pg_settings s
          WHERE s.name = 'relay.environment';
        PERFORM set_config('relay.tenant_id', relay_private.installation_tenant_id()::text, true);
        PERFORM set_config('relay.environment', 'live', true);
        SELECT true, max((r.value ->> 'days')::bigint)
            FILTER (WHERE r.value ->> 'retention_class' = ANY (p_classes))
          INTO v_found, v_days
          FROM relay.dataset_active a
          JOIN relay.dataset_versions v ON v.tenant_id = a.tenant_id
            AND v.environment = a.environment AND v.id = a.version_id
          LEFT JOIN LATERAL jsonb_array_elements(v.content -> 'periods') r ON true
          WHERE a.tenant_id = relay_private.installation_tenant_id() AND a.environment = 'live'
            AND a.dataset_name = 'retention_periods'
          GROUP BY a.version_id;
        PERFORM set_config('relay.tenant_id', COALESCE(v_saved_tenant, ''), true);
        PERFORM set_config('relay.environment', COALESCE(v_saved_environment, ''), true);
        IF NOT COALESCE(v_found, false) THEN
          RETURN NULL;
        END IF;
        RETURN COALESCE(v_days, 0);
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.archive_leaves()
        RETURNS TABLE (table_name text, leaf_name text, range_from timestamptz,
          range_to timestamptz, retain_days bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      BEGIN
        RETURN QUERY
        WITH leaves AS (
          SELECT p.table_name, c.relname::text AS leaf_name, p.partition_interval,
            p.archive_retention_classes,
            substr(c.relname::text, char_length(p.table_name) + 3) AS stamp
          FROM relay.partition_policies p
          JOIN pg_class c ON c.relnamespace = 'relay'::regnamespace AND c.relkind = 'r'
            AND NOT c.relispartition AND starts_with(c.relname::text, p.table_name || '_p')
          WHERE NOT EXISTS (SELECT 1 FROM pg_inherits i
            WHERE i.inhrelid = c.oid OR i.inhparent = c.oid)
        ),
        bounded AS (
          SELECT l.*,
            to_date(CASE l.partition_interval WHEN 'day' THEN l.stamp ELSE l.stamp || '01' END,
              'YYYYMMDD')::timestamptz AS lower_bound
          FROM leaves l
          WHERE (l.partition_interval = 'day' AND l.stamp ~ '^[0-9]{8}$')
            OR (l.partition_interval = 'month' AND l.stamp ~ '^[0-9]{6}$')
        )
        SELECT b.table_name, b.leaf_name, b.lower_bound,
          b.lower_bound + CASE b.partition_interval WHEN 'day' THEN interval '1 day'
            ELSE interval '1 month' END,
          relay_private.archive_retain_days(b.archive_retention_classes)
        FROM bounded b
        ORDER BY 4, 1, 2;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.archive_leader(p_token bigint) RETURNS boolean
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT EXISTS (SELECT 1 FROM relay.singleton_tasks t
          WHERE t.name = 'partition_archive' AND t.fencing_token = p_token
            AND t.lease_until > now())
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.archive_begin(p_id uuid, p_table text, p_leaf text,
        p_object_key text, p_schema_key text, p_retain_until timestamptz, p_token bigint)
        RETURNS TABLE (result text, migration_version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_leaf record;
        v_version bigint;
      BEGIN
        IF session_user <> 'relay_archive' THEN
          RAISE EXCEPTION 'insufficient_privilege' USING HINT = 'INV-47';
        END IF;
        IF p_id IS NULL OR p_object_key IS NULL OR p_schema_key IS NULL
          OR p_retain_until IS NULL OR p_token IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-84';
        END IF;
        IF NOT relay_private.archive_leader(p_token) THEN
          RETURN QUERY SELECT 'not_leader'::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT * INTO v_leaf FROM relay_private.archive_leaves() l
          WHERE l.table_name = p_table AND l.leaf_name = p_leaf;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_detached'::text, NULL::bigint;
          RETURN;
        END IF;
        UPDATE relay.archive_manifests m SET status = 'failed', failure_code = 'superseded',
            failed_at = now()
          WHERE m.leaf_name = p_leaf AND m.status IN ('started', 'verified');
        SELECT max(s.version) INTO v_version FROM relay.schema_migrations s;
        INSERT INTO relay.archive_manifests (id, table_name, leaf_name, range_from, range_to,
            object_key, schema_key, migration_version, retain_until, status, fencing_token,
            started_at)
          VALUES (p_id, p_table, p_leaf, v_leaf.range_from, v_leaf.range_to, p_object_key,
            p_schema_key, v_version, p_retain_until, 'started', p_token, now());
        RETURN QUERY SELECT 'started'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.archive_verified(p_id uuid, p_row_count bigint,
        p_digest bytea, p_file_bytes bigint, p_token bigint) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_status text;
      BEGIN
        IF session_user <> 'relay_archive' THEN
          RAISE EXCEPTION 'insufficient_privilege' USING HINT = 'INV-47';
        END IF;
        IF p_row_count IS NULL OR p_row_count < 0 OR p_digest IS NULL
          OR octet_length(p_digest) <> 32 OR p_file_bytes IS NULL OR p_file_bytes < 0 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-84';
        END IF;
        IF NOT relay_private.archive_leader(p_token) THEN
          RETURN 'not_leader';
        END IF;
        SELECT m.status INTO v_status FROM relay.archive_manifests m WHERE m.id = p_id FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_status <> 'started' THEN
          RETURN 'not_started';
        END IF;
        UPDATE relay.archive_manifests m SET status = 'verified', row_count = p_row_count,
            digest = p_digest, file_bytes = p_file_bytes, verified_at = now()
          WHERE m.id = p_id;
        RETURN 'verified';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.archive_failed(p_id uuid, p_code text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_status text;
      BEGIN
        IF session_user <> 'relay_archive' THEN
          RAISE EXCEPTION 'insufficient_privilege' USING HINT = 'INV-47';
        END IF;
        SELECT m.status INTO v_status FROM relay.archive_manifests m WHERE m.id = p_id FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_status NOT IN ('started', 'verified') THEN
          RETURN 'not_started';
        END IF;
        UPDATE relay.archive_manifests m SET status = 'failed',
            failure_code = left(COALESCE(p_code, 'unknown'), 64), failed_at = now()
          WHERE m.id = p_id;
        RETURN 'failed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.archive_drop(p_id uuid, p_token bigint) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      SET lock_timeout = '2s'
      AS $fn$
      DECLARE
        v_manifest relay.archive_manifests;
        v_count bigint;
      BEGIN
        IF session_user <> 'relay_archive' THEN
          RAISE EXCEPTION 'insufficient_privilege' USING HINT = 'INV-47';
        END IF;
        IF NOT relay_private.archive_leader(p_token) THEN
          RETURN 'not_leader';
        END IF;
        SELECT * INTO v_manifest FROM relay.archive_manifests m WHERE m.id = p_id FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_manifest.status <> 'verified' THEN
          RETURN 'not_verified';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM relay_private.archive_leaves() l
          WHERE l.table_name = v_manifest.table_name AND l.leaf_name = v_manifest.leaf_name) THEN
          RETURN 'not_detached';
        END IF;
        BEGIN
          EXECUTE format('ALTER TABLE relay.%I NO FORCE ROW LEVEL SECURITY', v_manifest.leaf_name);
          EXECUTE format('SELECT count(*) FROM relay.%I', v_manifest.leaf_name) INTO v_count;
          IF v_count <> v_manifest.row_count THEN
            RAISE EXCEPTION 'count_mismatch';
          END IF;
          EXECUTE format('DROP TABLE relay.%I', v_manifest.leaf_name);
        EXCEPTION
          WHEN lock_not_available OR query_canceled THEN
            RETURN 'lock_timeout';
          WHEN raise_exception THEN
            RETURN 'count_mismatch';
        END;
        UPDATE relay.archive_manifests m SET status = 'archived', archived_at = now()
          WHERE m.id = p_id;
        RETURN 'archived';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.restore_prepare(p_schema text, p_table text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_column text;
      BEGIN
        IF session_user <> 'relay_archive' THEN
          RAISE EXCEPTION 'insufficient_privilege' USING HINT = 'OP-84';
        END IF;
        IF p_schema IS NULL OR p_schema !~ '^restore_[a-z0-9_]{1,54}$' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-84';
        END IF;
        SELECT a.attname::text INTO v_column
          FROM pg_partitioned_table pt
          JOIN pg_class c ON c.oid = pt.partrelid
          JOIN pg_attribute a ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
          WHERE c.relnamespace = 'relay'::regnamespace AND c.relname = p_table
            AND pt.partstrat = 'r';
        IF NOT FOUND THEN
          RETURN 'not_partitioned';
        END IF;
        IF EXISTS (SELECT 1 FROM pg_namespace n WHERE n.nspname = p_schema) THEN
          RETURN 'exists';
        END IF;
        EXECUTE format('CREATE SCHEMA %I', p_schema);
        EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', p_schema);
        EXECUTE format('CREATE TABLE %I.%I (LIKE relay.%I INCLUDING DEFAULTS INCLUDING CONSTRAINTS) PARTITION BY RANGE (%I)',
          p_schema, p_table, p_table, v_column);
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO relay_archive, relay_maint', p_schema);
        RETURN 'prepared';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.staging_create(p_schema text, p_table text, p_leaf text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF p_schema IS NULL OR p_schema !~ '^restore_[a-z0-9_]{1,54}$'
          OR p_leaf IS NULL OR p_leaf !~ '^[a-z_][a-z0-9_]{0,62}$' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-14';
        END IF;
        IF to_regclass(format('%I.%I', p_schema, p_table)) IS NULL THEN
          RETURN 'not_found';
        END IF;
        IF to_regclass(format('%I.%I', p_schema, p_leaf)) IS NOT NULL THEN
          RETURN 'exists';
        END IF;
        EXECUTE format('CREATE TABLE %I.%I (LIKE %I.%I INCLUDING DEFAULTS INCLUDING CONSTRAINTS)',
          p_schema, p_leaf, p_schema, p_table);
        EXECUTE format('GRANT SELECT, INSERT ON %I.%I TO relay_archive', p_schema, p_leaf);
        RETURN 'created';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.staging_attach(p_schema text, p_table text, p_leaf text,
        p_from timestamptz, p_to timestamptz) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      SET lock_timeout = '2s'
      AS $fn$
      DECLARE
        v_column text;
        v_type text;
        v_from text;
        v_to text;
      BEGIN
        IF p_schema IS NULL OR p_schema !~ '^restore_[a-z0-9_]{1,54}$'
          OR p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-14';
        END IF;
        SELECT a.attname::text, format_type(a.atttypid, a.atttypmod) INTO v_column, v_type
          FROM pg_partitioned_table pt
          JOIN pg_attribute a ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
          WHERE pt.partrelid = to_regclass(format('%I.%I', p_schema, p_table));
        IF NOT FOUND OR to_regclass(format('%I.%I', p_schema, p_leaf)) IS NULL THEN
          RETURN 'not_found';
        END IF;
        IF v_type = 'date' THEN
          v_from := p_from::date::text;
          v_to := p_to::date::text;
        ELSE
          v_from := p_from::text;
          v_to := p_to::text;
        END IF;
        BEGIN
          EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%I >= %L::%s AND %I < %L::%s)',
            p_schema, p_leaf, left(p_leaf, 57) || '_bound', v_column, v_from, v_type, v_column,
            v_to, v_type);
          EXECUTE format('ALTER TABLE %I.%I ATTACH PARTITION %I.%I FOR VALUES FROM (%L) TO (%L)',
            p_schema, p_table, p_schema, p_leaf, v_from, v_to);
        EXCEPTION WHEN lock_not_available OR query_canceled THEN
          RETURN 'lock_timeout';
        END;
        RETURN 'attached';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.restore_seal(p_schema text, p_table text, p_leaf text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF p_schema IS NULL OR p_schema !~ '^restore_[a-z0-9_]{1,54}$' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-84';
        END IF;
        IF to_regclass(format('%I.%I', p_schema, p_table)) IS NULL
          OR to_regclass(format('%I.%I', p_schema, p_leaf)) IS NULL THEN
          RETURN 'not_found';
        END IF;
        EXECUTE format('REVOKE INSERT ON %I.%I FROM relay_archive', p_schema, p_leaf);
        EXECUTE format('CREATE TRIGGER restore_read_only BEFORE INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION relay_private.reject_mutation()',
          p_schema, p_leaf);
        EXECUTE format('CREATE TRIGGER restore_no_truncate BEFORE TRUNCATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION relay_private.reject_mutation()',
          p_schema, p_leaf);
        EXECUTE format('GRANT SELECT ON %I.%I, %I.%I TO relay_archive, relay_maint',
          p_schema, p_table, p_schema, p_leaf);
        RETURN 'sealed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.partitioned_index_plan(p_table text, p_index text,
        p_definition text) RETURNS TABLE (step integer, sql_text text)
      LANGUAGE plpgsql STABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_parent regclass;
        v_leaf text;
        v_leaf_index text;
        v_step integer := 1;
      BEGIN
        IF p_table IS NULL OR p_table !~ '^[a-z_][a-z0-9_]{0,62}$'
          OR p_index IS NULL OR p_index !~ '^[a-z_][a-z0-9_]{0,62}$'
          OR p_definition IS NULL OR p_definition !~ '^\(' OR p_definition ~ ';' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-14';
        END IF;
        v_parent := to_regclass(format('relay.%I', p_table));
        IF v_parent IS NULL
          OR NOT EXISTS (SELECT 1 FROM pg_partitioned_table pt WHERE pt.partrelid = v_parent) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-14';
        END IF;
        step := v_step;
        sql_text := format('CREATE INDEX IF NOT EXISTS %I ON ONLY relay.%I %s', p_index, p_table,
          p_definition);
        RETURN NEXT;
        FOR v_leaf IN
          SELECT c.relname::text FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
          WHERE i.inhparent = v_parent ORDER BY c.relname
        LOOP
          v_leaf_index := left(CASE WHEN starts_with(p_index, p_table)
            THEN v_leaf || substr(p_index, char_length(p_table) + 1)
            ELSE v_leaf || '_' || p_index END, 63);
          v_step := v_step + 1;
          step := v_step;
          sql_text := format('CREATE INDEX CONCURRENTLY IF NOT EXISTS %I ON relay.%I %s',
            v_leaf_index, v_leaf, p_definition);
          RETURN NEXT;
          v_step := v_step + 1;
          step := v_step;
          sql_text := format('ALTER INDEX relay.%I ATTACH PARTITION relay.%I', p_index,
            v_leaf_index);
          RETURN NEXT;
        END LOOP;
      END
      $fn$
      """
    ]
  end
end
