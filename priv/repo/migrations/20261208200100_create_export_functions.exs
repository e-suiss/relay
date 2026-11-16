defmodule Relay.Repo.Migrations.CreateExportFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    "relay_fn.export_request(uuid, text, date, date, text, bytea, #{@actor})",
    "relay_fn.export_complete(uuid, bytea, bigint, bytea, timestamptz)",
    "relay_fn.export_fail(uuid, text)",
    "relay_fn.export_download(uuid, bytea, #{@actor})",
    "relay_fn.export_expire()"
  ]

  # DS-37
  # OP-39
  # TN-18
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
      CREATE FUNCTION relay_fn.export_request(p_id uuid, p_kind text, p_period_start date,
        p_period_end date, p_requested_by text, p_record_digest bytea, p_actor_kind text,
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
        IF p_kind IS NULL OR p_period_start IS NULL OR p_period_end IS NULL
          OR p_requested_by IS NULL OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-37';
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.exports (tenant_id, environment, id, kind, format, period_start,
          period_end, state, requested_by, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_kind, 'csv', p_period_start, p_period_end, 'pending',
          p_requested_by, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'export.requested',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'export', p_id::text, p_kind, p_record_digest);
        RETURN 'requested';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.export_complete(p_id uuid, p_content bytea, p_row_count bigint,
        p_content_sha256 bytea, p_expires_at timestamptz)
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
        IF p_content IS NULL OR p_row_count IS NULL OR p_row_count < 0
          OR p_content_sha256 IS NULL OR sha256(p_content) <> p_content_sha256
          OR p_expires_at IS NULL OR p_expires_at <= now() THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-37';
        END IF;
        SELECT x.state INTO v_state FROM relay.exports x
          WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state <> 'pending' THEN
          RETURN 'not_pending';
        END IF;
        UPDATE relay.exports x SET state = 'ready', content = p_content, row_count = p_row_count,
            byte_size = octet_length(p_content), content_sha256 = p_content_sha256,
            expires_at = p_expires_at, completed_at = now(), updated_at = now()
          WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.id = p_id;
        RETURN 'completed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.export_fail(p_id uuid, p_failure text)
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
        IF p_failure IS NULL OR p_failure NOT IN ('too_large', 'unavailable') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-37';
        END IF;
        SELECT x.state INTO v_state FROM relay.exports x
          WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state <> 'pending' THEN
          RETURN 'not_pending';
        END IF;
        UPDATE relay.exports x SET state = 'failed', failure = p_failure, completed_at = now(),
            updated_at = now()
          WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.id = p_id;
        RETURN 'failed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.export_download(p_id uuid, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.exports;
      BEGIN
        IF p_id IS NULL OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'DS-37';
        END IF;
        SELECT * INTO v_row FROM relay.exports x
          WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.state = 'ready' AND v_row.expires_at <= now() THEN
          UPDATE relay.exports x SET state = 'expired', content = NULL, updated_at = now()
            WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.id = p_id;
          RETURN 'expired';
        END IF;
        IF v_row.state = 'expired' THEN
          RETURN 'expired';
        END IF;
        IF v_row.state <> 'ready' THEN
          RETURN 'not_ready';
        END IF;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'export.downloaded',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'export', p_id::text, v_row.kind, p_record_digest);
        RETURN 'ready';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.export_expire()
        RETURNS bigint
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_count bigint;
      BEGIN
        UPDATE relay.exports x SET state = 'expired', content = NULL, updated_at = now()
          WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.state = 'ready'
            AND x.expires_at <= now();
        GET DIAGNOSTICS v_count = ROW_COUNT;
        RETURN v_count;
      END
      $fn$
      """
    ]
  end
end
