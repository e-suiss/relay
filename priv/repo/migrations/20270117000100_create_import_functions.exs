defmodule Relay.Repo.Migrations.CreateImportFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    "relay_fn.import_request(uuid, text, text, bigint, bigint, bytea, bytea, uuid, text, bytea, #{@actor})",
    "relay_fn.import_record(uuid, bigint[], text[], text[], uuid[], bytea[], timestamptz[])",
    "relay_fn.import_complete(uuid, jsonb)",
    "relay_fn.import_fail(uuid, text)"
  ]

  # OP-96
  # OP-55
  # OP-97
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.import_request(p_id uuid, p_kind text, p_batch text,
        p_line_count bigint, p_byte_size bigint, p_content_sha256 bytea, p_content_ct bytea,
        p_content_key_id uuid, p_requested_by text, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        IF p_kind IS NULL OR p_batch IS NULL OR p_line_count IS NULL OR p_byte_size IS NULL
          OR p_content_sha256 IS NULL OR p_content_ct IS NULL OR p_content_key_id IS NULL
          OR p_requested_by IS NULL OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-96';
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        IF p_kind IN ('subscribers', 'devices', 'scheduled') AND (
          NOT EXISTS (SELECT 1 FROM relay.imports i
            WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.batch = p_batch
              AND i.kind = 'suppressions' AND i.state = 'completed')
          OR NOT EXISTS (SELECT 1 FROM relay.imports i
            WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.batch = p_batch
              AND i.kind = 'consents' AND i.state = 'completed')
          OR EXISTS (SELECT 1 FROM relay.imports i
            WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.batch = p_batch
              AND i.kind IN ('suppressions', 'consents') AND i.state <> 'completed')) THEN
          RETURN 'order_violation';
        END IF;
        INSERT INTO relay.imports (tenant_id, environment, id, kind, batch, state, line_count,
          byte_size, content_sha256, content_ct, content_key_id, requested_by, created_at,
          updated_at)
        VALUES (v_tenant, v_env, p_id, p_kind, p_batch, 'pending', p_line_count, p_byte_size,
          p_content_sha256, p_content_ct, p_content_key_id, p_requested_by, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'import.requested',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'import', p_id::text, p_kind, p_record_digest);
        RETURN 'requested';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.import_record(p_import_id uuid, p_lines bigint[],
        p_entity_kinds text[], p_entity_keys text[], p_recipient_ids uuid[],
        p_provider_ref_cts bytea[], p_source_last_seen_ats timestamptz[])
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_state text;
        v_count integer := coalesce(cardinality(p_lines), 0);
      BEGIN
        IF p_import_id IS NULL
          OR coalesce(cardinality(p_entity_kinds), 0) <> v_count
          OR coalesce(cardinality(p_entity_keys), 0) <> v_count
          OR coalesce(cardinality(p_recipient_ids), 0) <> v_count
          OR coalesce(cardinality(p_provider_ref_cts), 0) <> v_count
          OR coalesce(cardinality(p_source_last_seen_ats), 0) <> v_count THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-55';
        END IF;
        SELECT i.state INTO v_state FROM relay.imports i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_import_id
          FOR SHARE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state <> 'pending' THEN
          RETURN 'not_pending';
        END IF;
        INSERT INTO relay.import_records (tenant_id, environment, id, import_id, line,
          entity_kind, entity_key, recipient_id, provider_ref_ct, source_last_seen_at,
          migrated_at, created_at)
        SELECT v_tenant, v_env, uuidv7(), p_import_id, r.line, r.entity_kind, r.entity_key,
          r.recipient_id, r.provider_ref_ct, r.source_last_seen_at, now(), now()
        FROM unnest(p_lines, p_entity_kinds, p_entity_keys, p_recipient_ids, p_provider_ref_cts,
          p_source_last_seen_ats)
          AS r(line, entity_kind, entity_key, recipient_id, provider_ref_ct, source_last_seen_at)
        ON CONFLICT (tenant_id, environment, import_id, line, entity_kind) DO NOTHING;
        RETURN 'recorded';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.import_complete(p_id uuid, p_report jsonb)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_state text;
      BEGIN
        IF p_id IS NULL OR p_report IS NULL OR jsonb_typeof(p_report) <> 'object' THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-96';
        END IF;
        SELECT i.state INTO v_state FROM relay.imports i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state <> 'pending' THEN
          RETURN 'not_pending';
        END IF;
        UPDATE relay.imports i SET state = 'completed', report = p_report, content_ct = NULL,
            content_key_id = NULL, completed_at = now(), updated_at = now()
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id;
        RETURN 'completed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.import_fail(p_id uuid, p_failure text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_state text;
      BEGIN
        IF p_id IS NULL OR p_failure IS NULL
          OR p_failure NOT IN ('unavailable', 'content_unreadable') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-96';
        END IF;
        SELECT i.state INTO v_state FROM relay.imports i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state <> 'pending' THEN
          RETURN 'not_pending';
        END IF;
        UPDATE relay.imports i SET state = 'failed', failure = p_failure, content_ct = NULL,
            content_key_id = NULL, completed_at = now(), updated_at = now()
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id;
        RETURN 'failed';
      END
      $fn$
      """
    ]
  end
end
