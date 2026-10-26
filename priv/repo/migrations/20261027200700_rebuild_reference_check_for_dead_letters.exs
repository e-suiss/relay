defmodule Relay.Repo.Migrations.RebuildReferenceCheckForDeadLetters do
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
    {"dead_letters", "dead_letters_delivery_id_fkey", "tenant_id,environment,delivery_id",
     "deliveries", "tenant_id,environment,id"},
    {"dead_letters", "dead_letters_notification_id_fkey",
     "tenant_id,environment,notification_id,recipient_id", "notifications",
     "tenant_id,environment,id,recipient_id"},
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
  # T-29
  def up do
    execute("DROP FUNCTION relay_ops.reference_check()")
    execute(reference_check())
    execute("REVOKE ALL ON FUNCTION relay_ops.reference_check() FROM PUBLIC")
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
      UNION ALL
      SELECT 'dead_letter_replay_of_missing'::text, 'dead_letters'::text, count(*)
      FROM relay.dead_letters l
      WHERE l.replay_of_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.dead_letters x
        WHERE x.tenant_id = l.tenant_id AND x.environment = l.environment
          AND x.id = l.replay_of_id AND x.created_at = l.replay_of_created_at)
      UNION ALL
      SELECT 'replay_dead_letter_missing'::text, 'deliveries'::text, count(*)
      FROM relay.deliveries d
      WHERE d.replay_dead_letter_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.dead_letters x
        WHERE x.tenant_id = d.tenant_id AND x.environment = d.environment
          AND x.id = d.replay_dead_letter_id AND x.created_at = d.replay_dead_letter_created_at)
      UNION ALL
      SELECT 'channel_parameters_version_missing'::text, 'dead_letters'::text, count(*)
      FROM relay.dead_letters l
      WHERE l.channel_parameters_version_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM relay.dataset_versions v
        WHERE v.id = l.channel_parameters_version_id AND v.dataset_name = 'channel_parameters')
    $fn$
    """
  end
end
