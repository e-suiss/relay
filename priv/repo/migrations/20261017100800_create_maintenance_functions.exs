defmodule Relay.Repo.Migrations.CreateMaintenanceFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_private.partition_upper_bound(oid)", "relay_migrator", ~w(relay_maint)},
    {"relay_private.partition_create(text, timestamp with time zone, timestamp with time zone)",
     "relay_migrator", ~w(relay_maint)},
    {"relay_private.parent_analyze(text)", "relay_migrator", ~w(relay_maint)},
    {"relay_ops.partition_horizon()", "relay_maint", ~w(relay_worker)},
    {"relay_ops.partition_due_for_archive()", "relay_maint", []},
    {"relay_ops.partition_policy_set(text, text, interval, interval, bytea, #{@actor})",
     "relay_maint", ~w(relay_app)},
    {"relay_ops.orphan_check()", "relay_maint", []},
    {"relay_ops.singleton_acquire(text, text, interval)", "relay_maint", ~w(relay_worker)},
    {"relay_ops.singleton_save(text, bigint, jsonb)", "relay_maint", ~w(relay_worker)}
  ]

  # OP-13
  # OP-14
  # OP-42
  # T-12
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_private.partition_upper_bound(p_partition oid) RETURNS timestamptz
      LANGUAGE sql STABLE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT substring(pg_get_expr(c.relpartbound, c.oid) FROM 'TO \(''([^'']+)''\)')::timestamptz
        FROM pg_class c WHERE c.oid = p_partition
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.partition_create(p_table text, p_from timestamptz,
        p_to timestamptz) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      SET lock_timeout = '1s'
      SET statement_timeout = '10s'
      AS $fn$
      DECLARE
        v_policy relay.partition_policies;
        v_parent oid;
        v_column text;
        v_type text;
        v_name text;
        v_from text;
        v_to text;
        v_bound text;
        v_policy_row record;
        v_trigger record;
      BEGIN
        IF p_table IS NULL OR p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-14';
        END IF;
        SELECT * INTO v_policy FROM relay.partition_policies p WHERE p.table_name = p_table;
        IF NOT FOUND THEN
          RETURN 'policy_missing';
        END IF;
        IF v_policy.partition_interval = 'day' THEN
          IF p_from <> date_trunc('day', p_from) OR p_to <> p_from + interval '1 day' THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-13';
          END IF;
          v_name := p_table || '_p' || to_char(p_from, 'YYYYMMDD');
        ELSE
          IF p_from <> date_trunc('month', p_from) OR p_to <> p_from + interval '1 month' THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-13';
          END IF;
          v_name := p_table || '_p' || to_char(p_from, 'YYYYMM');
        END IF;
        SELECT pt.partrelid, a.attname::text, format_type(a.atttypid, a.atttypmod)
          INTO v_parent, v_column, v_type
          FROM pg_partitioned_table pt
          JOIN pg_class c ON c.oid = pt.partrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_attribute a ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
          WHERE n.nspname = 'relay' AND c.relname = p_table;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-13';
        END IF;
        IF v_type = 'date' THEN
          v_from := p_from::date::text;
          v_to := p_to::date::text;
        ELSE
          v_from := p_from::text;
          v_to := p_to::text;
        END IF;
        v_bound := format('FOR VALUES FROM (%L) TO (%L)', v_from, v_to);
        IF EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
          WHERE i.inhparent = v_parent
            AND (c.relname = v_name OR pg_get_expr(c.relpartbound, c.oid) = v_bound)) THEN
          RETURN 'exists';
        END IF;
        BEGIN
          EXECUTE format('CREATE TABLE relay.%I (LIKE relay.%I INCLUDING ALL)', v_name, p_table);
          EXECUTE format('ALTER TABLE relay.%I ADD CONSTRAINT %I CHECK (%I >= %L::%s AND %I < %L::%s)',
            v_name, v_name || '_bound', v_column, v_from, v_type, v_column, v_to, v_type);
          EXECUTE format('ALTER TABLE relay.%I ENABLE ROW LEVEL SECURITY', v_name);
          EXECUTE format('ALTER TABLE relay.%I FORCE ROW LEVEL SECURITY', v_name);
          FOR v_policy_row IN
            SELECT p.policyname::text AS name, p.permissive, p.cmd, p.qual, p.with_check,
              (SELECT string_agg(CASE WHEN r = 'public' THEN 'PUBLIC' ELSE quote_ident(r) END, ', ')
                FROM unnest(p.roles) AS r) AS roles
            FROM pg_policies p
            WHERE p.schemaname = 'relay' AND p.tablename = p_table
            ORDER BY p.policyname
          LOOP
            EXECUTE format('CREATE POLICY %I ON relay.%I AS %s FOR %s TO %s%s%s',
              CASE WHEN starts_with(v_policy_row.name, p_table)
                THEN v_name || substr(v_policy_row.name, char_length(p_table) + 1)
                ELSE v_policy_row.name END,
              v_name, v_policy_row.permissive, v_policy_row.cmd, v_policy_row.roles,
              CASE WHEN v_policy_row.qual IS NULL THEN ''
                ELSE ' USING (' || v_policy_row.qual || ')' END,
              CASE WHEN v_policy_row.with_check IS NULL THEN ''
                ELSE ' WITH CHECK (' || v_policy_row.with_check || ')' END);
          END LOOP;
          FOR v_trigger IN
            SELECT pg_get_triggerdef(t.oid) AS definition
            FROM pg_trigger t
            WHERE t.tgrelid = v_parent AND NOT t.tgisinternal AND (t.tgtype & 1) = 0
            ORDER BY t.tgname
          LOOP
            EXECUTE replace(v_trigger.definition, format(' ON relay.%I ', p_table),
              format(' ON relay.%I ', v_name));
          END LOOP;
          EXECUTE format('GRANT SELECT ON relay.%I TO relay_maint, relay_archive', v_name);
          EXECUTE format('ALTER TABLE relay.%I ATTACH PARTITION relay.%I %s', p_table, v_name, v_bound);
        EXCEPTION WHEN lock_not_available OR query_canceled THEN
          RETURN 'lock_timeout';
        END;
        RETURN 'created';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.parent_analyze(p_table text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_partitioned_table pt
          JOIN pg_class c ON c.oid = pt.partrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'relay' AND c.relname = p_table) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-14';
        END IF;
        EXECUTE format('ANALYZE relay.%I', p_table);
        RETURN 'analyzed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.partition_horizon()
        RETURNS TABLE (table_name text, furthest_bound timestamptz, ok boolean)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT p.table_name, b.furthest,
          COALESCE(b.furthest >= now() + p.alarm_threshold, false)
        FROM relay.partition_policies p
        LEFT JOIN LATERAL (
          SELECT max(relay_private.partition_upper_bound(i.inhrelid)) AS furthest
          FROM pg_inherits i
          WHERE i.inhparent = to_regclass(format('relay.%I', p.table_name))
        ) b ON true
        ORDER BY p.table_name
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.partition_due_for_archive()
        RETURNS TABLE (table_name text, partition_name text, upper_bound timestamptz)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT p.table_name, c.relname::text, relay_private.partition_upper_bound(c.oid)
        FROM relay.partition_policies p
        JOIN pg_inherits i ON i.inhparent = to_regclass(format('relay.%I', p.table_name))
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE relay_private.partition_upper_bound(c.oid) < now() - p.hot_retention
        ORDER BY 3, 1, 2
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.partition_policy_set(p_table text, p_interval text,
        p_premake interval, p_hot_retention interval, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_policy relay.partition_policies;
      BEGIN
        IF p_interval IS NULL OR p_interval NOT IN ('day', 'month')
          OR p_premake IS NULL OR p_premake <= interval '0'
          OR p_hot_retention IS NULL OR p_hot_retention <= interval '0' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-13';
        END IF;
        SELECT * INTO v_policy FROM relay.partition_policies p WHERE p.table_name = p_table
          FOR UPDATE;
        IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM pg_partitioned_table pt
          WHERE pt.partrelid = to_regclass(format('relay.%I', p_table))) THEN
          RETURN 'not_partitioned';
        END IF;
        IF v_policy.partition_interval = p_interval AND v_policy.premake_horizon = p_premake
          AND v_policy.hot_retention = p_hot_retention THEN
          RETURN 'unchanged';
        END IF;
        UPDATE relay.partition_policies p SET partition_interval = p_interval,
            premake_horizon = p_premake, hot_retention = p_hot_retention, updated_at = now(),
            updated_by_ref = p_actor_ref
          WHERE p.table_name = p_table;
        PERFORM relay_private.audit_write(relay_private.installation_tenant_id(), 'live',
          'partition_policy.updated', p_actor_kind, p_actor_ref, p_on_behalf_of_ref,
          p_access_record_ref, 'partition_policy', p_table, NULL, p_record_digest);
        RETURN 'updated';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.orphan_check()
        RETURNS TABLE (check_name text, table_name text, violations bigint)
      LANGUAGE plpgsql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_table record;
        v_count bigint;
      BEGIN
        FOR v_table IN
          SELECT c.relname::text AS name,
            EXISTS (SELECT 1 FROM pg_attribute e WHERE e.attrelid = c.oid
              AND e.attname = 'environment' AND NOT e.attisdropped) AS has_environment
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
          WHERE n.nspname = 'relay' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
          ORDER BY c.relname
        LOOP
          EXECUTE format('SELECT count(*) FROM relay.%I t WHERE t.tenant_id IS NULL%s', v_table.name,
            CASE WHEN v_table.has_environment THEN ' OR t.environment IS NULL' ELSE '' END)
            INTO v_count;
          check_name := 'null_scope';
          table_name := v_table.name;
          violations := v_count;
          RETURN NEXT;
          EXECUTE format('SELECT count(*) FROM relay.%I t WHERE NOT EXISTS '
            || '(SELECT 1 FROM relay.tenants x WHERE x.id = t.tenant_id)', v_table.name)
            INTO v_count;
          check_name := 'tenant_missing';
          violations := v_count;
          RETURN NEXT;
        END LOOP;
        RETURN QUERY
          SELECT 'ledger_attempt_missing'::text, 'delivery_events'::text, count(*)
          FROM relay.delivery_events e
          WHERE e.attempt_no IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM relay.delivery_attempts a
            WHERE a.tenant_id = e.tenant_id AND a.environment = e.environment
              AND a.delivery_id = e.delivery_id AND a.attempt_no = e.attempt_no);
        RETURN QUERY
          SELECT 'audit_leaf_without_record'::text, 'audit_leaves'::text, count(*)
          FROM relay.audit_leaves l
          WHERE NOT EXISTS (SELECT 1 FROM relay.audit_log a
            WHERE a.tenant_id = l.audit_tenant_id AND a.environment = l.audit_environment
              AND a.id = l.audit_id AND a.created_at = l.audit_created_at);
        RETURN QUERY
          SELECT 'audit_target_missing'::text, 'audit_log'::text, count(*)
          FROM relay.audit_log a
          WHERE (a.target_type = 'tenant' AND NOT EXISTS (SELECT 1 FROM relay.tenants x
              WHERE x.id::text = a.target_id))
            OR (a.target_type = 'subtenant' AND NOT EXISTS (SELECT 1 FROM relay.subtenants x
              WHERE x.tenant_id = a.tenant_id AND x.environment = a.environment
                AND x.id::text = a.target_id))
            OR (a.target_type = 'recipient' AND NOT EXISTS (SELECT 1 FROM relay.recipients x
              WHERE x.tenant_id = a.tenant_id AND x.environment = a.environment
                AND x.id::text = a.target_id))
            OR (a.target_type = 'notification' AND NOT EXISTS (SELECT 1 FROM relay.notifications x
              WHERE x.tenant_id = a.tenant_id AND x.environment = a.environment
                AND x.id::text = a.target_id))
            OR (a.target_type = 'delivery' AND NOT EXISTS (SELECT 1 FROM relay.deliveries x
              WHERE x.tenant_id = a.tenant_id AND x.environment = a.environment
                AND x.id::text = a.target_id));
        RETURN QUERY
          SELECT 'partition_horizon'::text, h.table_name, 1::bigint
          FROM relay_ops.partition_horizon() h
          WHERE NOT h.ok;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.singleton_acquire(p_name text, p_node text, p_ttl interval)
        RETURNS TABLE (result text, fencing_token bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_task relay.singleton_tasks;
        v_token bigint;
      BEGIN
        IF p_name IS NULL OR p_node IS NULL OR p_ttl IS NULL OR p_ttl <= interval '0' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'T-12';
        END IF;
        INSERT INTO relay.singleton_tasks AS t (name, leader_node, lease_until, fencing_token, state,
          updated_at)
        VALUES (p_name, p_node, now() + p_ttl, 1, NULL, now())
        ON CONFLICT (name) DO NOTHING
        RETURNING t.fencing_token INTO v_token;
        IF v_token IS NOT NULL THEN
          RETURN QUERY SELECT 'acquired'::text, v_token;
          RETURN;
        END IF;
        SELECT * INTO v_task FROM relay.singleton_tasks t WHERE t.name = p_name FOR UPDATE;
        IF v_task.leader_node = p_node AND v_task.lease_until > now() THEN
          UPDATE relay.singleton_tasks t SET lease_until = now() + p_ttl, updated_at = now()
            WHERE t.name = p_name;
          RETURN QUERY SELECT 'renewed'::text, v_task.fencing_token;
          RETURN;
        END IF;
        IF v_task.lease_until IS NULL OR v_task.lease_until <= now() THEN
          UPDATE relay.singleton_tasks t SET leader_node = p_node, lease_until = now() + p_ttl,
              fencing_token = t.fencing_token + 1, updated_at = now()
            WHERE t.name = p_name
            RETURNING t.fencing_token INTO v_token;
          RETURN QUERY SELECT 'acquired'::text, v_token;
          RETURN;
        END IF;
        RETURN QUERY SELECT 'held_by_other'::text, NULL::bigint;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_ops.singleton_save(p_name text, p_fencing_token bigint, p_state jsonb)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      BEGIN
        UPDATE relay.singleton_tasks t SET state = p_state, updated_at = now()
          WHERE t.name = p_name AND t.fencing_token = p_fencing_token AND t.lease_until > now();
        IF FOUND THEN
          RETURN 'saved';
        END IF;
        RETURN 'not_leader';
      END
      $fn$
      """
    ]
  end
end
