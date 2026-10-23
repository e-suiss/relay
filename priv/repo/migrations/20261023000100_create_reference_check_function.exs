defmodule Relay.Repo.Migrations.CreateReferenceCheckFunction do
  use Ecto.Migration

  @foreign_keys [
    {"audit_checkpoint_publications", "audit_checkpoint_publications_checkpoint_id_fkey",
     "checkpoint_id", "audit_checkpoints", "id"},
    {"audit_log", "audit_log_details_key_id_fkey", "tenant_id,environment,details_key_id",
     "tenant_keys", "tenant_id,environment,id"},
    {"dataset_active", "dataset_active_dataset_name_fkey", "dataset_name", "datasets", "name"},
    {"dataset_active", "dataset_active_version_id_fkey", "tenant_id,environment,version_id",
     "dataset_versions", "tenant_id,environment,id"},
    {"dataset_versions", "dataset_versions_dataset_name_fkey", "dataset_name", "datasets",
     "name"},
    {"deliveries", "deliveries_fallback_of_fkey", "tenant_id,environment,fallback_of",
     "deliveries", "tenant_id,environment,id"},
    {"deliveries", "deliveries_notification_id_fkey",
     "tenant_id,environment,notification_id,recipient_id", "notifications",
     "tenant_id,environment,id,recipient_id"},
    {"delivery_attempts", "delivery_attempts_delivery_id_fkey",
     "tenant_id,environment,delivery_id", "deliveries", "tenant_id,environment,id"},
    {"delivery_events", "delivery_events_delivery_id_fkey", "tenant_id,environment,delivery_id",
     "deliveries", "tenant_id,environment,id"},
    {"delivery_events", "delivery_events_receipt_id_fkey", "tenant_id,environment,receipt_id",
     "webhook_receipts", "tenant_id,environment,id"},
    {"erasure_log", "erasure_log_recipient_id_fkey", "tenant_id,environment,recipient_id",
     "recipients", "tenant_id,environment,id"},
    {"idempotency_keys", "idempotency_keys_response_body_key_id_fkey",
     "tenant_id,environment,response_body_key_id", "tenant_keys", "tenant_id,environment,id"},
    {"installation", "installation_installation_tenant_id_fkey", "installation_tenant_id",
     "tenants", "id"},
    {"legal_holds", "legal_holds_recipient_id_fkey", "tenant_id,environment,recipient_id",
     "recipients", "tenant_id,environment,id"},
    {"notifications", "notifications_recipient_id_fkey", "tenant_id,environment,recipient_id",
     "recipients", "tenant_id,environment,id"},
    {"notifications", "notifications_subtenant_id_fkey", "tenant_id,environment,subtenant_id",
     "subtenants", "tenant_id,environment,id"},
    {"recipients", "recipients_external_id_bidx_key_id_fkey",
     "tenant_id,environment,external_id_bidx_key_id", "blind_index_keys",
     "tenant_id,environment,id"},
    {"recipients", "recipients_external_id_key_id_fkey",
     "tenant_id,environment,external_id_key_id", "subject_keys", "tenant_id,environment,id"},
    {"secret_refs", "secret_refs_secret_key_id_fkey", "tenant_id,environment,secret_key_id",
     "tenant_keys", "tenant_id,environment,id"},
    {"settings", "settings_subtenant_id_fkey", "tenant_id,environment,subtenant_id", "subtenants",
     "tenant_id,environment,id"},
    {"subject_keys", "subject_keys_recipient_id_fkey", "tenant_id,environment,recipient_id",
     "recipients", "tenant_id,environment,id"},
    {"subject_keys", "subject_keys_wrapping_key_id_fkey", "tenant_id,environment,wrapping_key_id",
     "tenant_keys", "tenant_id,environment,id"},
    {"subtenants", "subtenants_tenant_id_fkey", "tenant_id", "tenants", "id"},
    {"webhook_receipts", "webhook_receipts_body_key_id_fkey", "tenant_id,environment,body_key_id",
     "tenant_keys", "tenant_id,environment,id"}
  ]

  # OP-42
  # TN-12
  # TN-16
  # OP-14
  def up do
    execute(reference_check())
    execute("REVOKE ALL ON FUNCTION relay_ops.reference_check() FROM PUBLIC")
    execute(partition_create())
  end

  def down do
    execute("DROP FUNCTION relay_ops.reference_check()")
  end

  defp expected do
    Enum.map_join(@foreign_keys, ",\n          ", fn {table, name, cols, target, target_cols} ->
      "('#{table}', '#{name}', '#{cols}', '#{target}', '#{target_cols}')"
    end)
  end

  defp reference_check do
    """
    CREATE FUNCTION relay_ops.reference_check()
      RETURNS TABLE (check_name text, table_name text, violations bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      WITH expected (table_name, name, cols, target, target_cols) AS (
        VALUES
          #{expected()}
      ),
      actual AS (
        SELECT c.relname::text AS table_name, k.conname::text AS name,
          (SELECT string_agg(a.attname::text, ',' ORDER BY u.n) FROM unnest(k.conkey)
            WITH ORDINALITY AS u(attnum, n)
            JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.attnum) AS cols,
          t.relname::text AS target,
          (SELECT string_agg(a.attname::text, ',' ORDER BY u.n) FROM unnest(k.confkey)
            WITH ORDINALITY AS u(attnum, n)
            JOIN pg_attribute a ON a.attrelid = k.confrelid AND a.attnum = u.attnum) AS target_cols,
          k.convalidated
        FROM pg_constraint k
        JOIN pg_class c ON c.oid = k.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class t ON t.oid = k.confrelid
        WHERE k.contype = 'f' AND k.conparentid = 0 AND n.nspname = 'relay'
          AND NOT c.relispartition AND c.relname !~ '_p[0-9]{6,8}$'
      )
      SELECT 'fk_missing'::text, e.table_name, count(*) FILTER (WHERE a.name IS NULL)
      FROM expected e
      LEFT JOIN actual a ON a.table_name = e.table_name AND a.name = e.name AND a.cols = e.cols
        AND a.target = e.target AND a.target_cols = e.target_cols
      GROUP BY e.table_name
      UNION ALL
      SELECT 'fk_not_validated'::text, e.table_name, count(*) FILTER (WHERE NOT a.convalidated)
      FROM expected e
      JOIN actual a ON a.table_name = e.table_name AND a.name = e.name
      GROUP BY e.table_name
      UNION ALL
      SELECT 'fk_unlisted'::text, a.table_name, count(*)
      FROM actual a
      WHERE NOT EXISTS (SELECT 1 FROM expected e WHERE e.table_name = a.table_name
        AND e.name = a.name)
      GROUP BY a.table_name
      UNION ALL
      SELECT 'stream_head_missing'::text, 'outbox_events'::text, count(*)
      FROM relay.outbox_events o
      WHERE NOT EXISTS (SELECT 1 FROM relay.stream_heads h
        WHERE h.tenant_id = o.tenant_id AND h.environment = o.environment
          AND h.stream_key = o.stream_key
          AND (h.epoch > o.epoch OR (h.epoch = o.epoch AND h.last_seq >= o.seq)))
    $fn$
    """
  end

  defp partition_create do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.partition_create(p_table text, p_from timestamptz,
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
      v_saved_tenant text;
      v_saved_environment text;
      v_options text[];
      v_toast_options text[];
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
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
          WHERE i.inhparent = v_parent
            AND (c.relname = v_name OR pg_get_expr(c.relpartbound, c.oid) = v_bound)) THEN
          RETURN 'exists';
        END IF;
        SELECT c.reloptions, t.reloptions INTO v_options, v_toast_options
          FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
          LEFT JOIN pg_class t ON t.oid = c.reltoastrelid
          WHERE i.inhparent = v_parent
          ORDER BY relay_private.partition_upper_bound(c.oid) DESC NULLS LAST
          LIMIT 1;
        EXECUTE format('CREATE TABLE relay.%I (LIKE relay.%I INCLUDING ALL)', v_name, p_table);
        IF v_options IS NOT NULL THEN
          EXECUTE format('ALTER TABLE relay.%I SET (%s)', v_name, array_to_string(v_options, ', '));
        END IF;
        IF v_toast_options IS NOT NULL THEN
          EXECUTE format('ALTER TABLE relay.%I SET (%s)', v_name,
            (SELECT string_agg('toast.' || o, ', ') FROM unnest(v_toast_options) AS o));
        END IF;
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
          SELECT t.tgname::text AS name, pg_get_triggerdef(t.oid) AS definition
          FROM pg_trigger t
          WHERE t.tgrelid = v_parent AND NOT t.tgisinternal AND (t.tgtype & 1) = 0
            AND (t.tgtype & 32) <> 0
          ORDER BY t.tgname
        LOOP
          EXECUTE replace(replace(v_trigger.definition, format(' ON relay.%I ', p_table),
              format(' ON relay.%I ', v_name)),
            format('CREATE TRIGGER %I ', v_trigger.name),
            format('CREATE TRIGGER %I ', CASE WHEN starts_with(v_trigger.name, p_table)
              THEN v_name || substr(v_trigger.name, char_length(p_table) + 1)
              ELSE v_trigger.name END));
        END LOOP;
        EXECUTE format('GRANT SELECT ON relay.%I TO relay_maint, relay_archive', v_name);
        SELECT s.setting INTO v_saved_tenant FROM pg_settings s WHERE s.name = 'relay.tenant_id';
        SELECT s.setting INTO v_saved_environment FROM pg_settings s
          WHERE s.name = 'relay.environment';
        PERFORM set_config('relay.tenant_id', '00000000-0000-0000-0000-000000000000', true);
        PERFORM set_config('relay.environment', 'live', true);
        EXECUTE format('ALTER TABLE relay.%I ATTACH PARTITION relay.%I %s', p_table, v_name, v_bound);
        PERFORM set_config('relay.tenant_id', COALESCE(v_saved_tenant, ''), true);
        PERFORM set_config('relay.environment', COALESCE(v_saved_environment, ''), true);
      EXCEPTION WHEN lock_not_available OR query_canceled THEN
        RETURN 'lock_timeout';
      END;
      RETURN 'created';
    END
    $fn$
    """
  end
end
