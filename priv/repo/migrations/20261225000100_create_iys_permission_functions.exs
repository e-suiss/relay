defmodule Relay.Repo.Migrations.CreateIysPermissionFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @ts "timestamp with time zone"

  @functions [
    "relay_fn.iys_permissions_apply(uuid, text, text, text, jsonb, #{@ts})",
    "relay_fn.iys_permission_mark(uuid, text, #{@ts})",
    "relay_fn.iys_sync_record(uuid, jsonb, #{@ts})",
    "relay_fn.iys_upload_retry(uuid, text, bytea, #{@actor}, #{@ts})"
  ]

  @overview "relay_ops.iys_sync_overview(#{@ts}, bigint, bigint)"

  # PC-32
  # PC-33
  # PC-34
  # PC-62
  # OP-42
  # OP-8
  def up do
    Enum.each([apply_movements(), mark(), record(), retry(), overview()], &execute/1)

    for signature <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      execute("GRANT EXECUTE ON FUNCTION #{signature} TO relay_app")
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end

    execute("REVOKE ALL ON FUNCTION #{@overview} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@overview} TO relay_worker")
  end

  def down, do: :ok

  defp apply_movements do
    ~S"""
    CREATE FUNCTION relay_fn.iys_permissions_apply(p_brand_id uuid, p_origin text, p_feed text,
      p_cursor text, p_movements jsonb, p_now timestamptz)
      RETURNS TABLE (result text, applied bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_movement jsonb;
      v_digest bytea;
      v_alt bytea;
      v_registered timestamptz;
      v_current relay.iys_permissions;
      v_refusal text;
      v_applied bigint := 0;
    BEGIN
      IF p_brand_id IS NULL OR p_now IS NULL OR p_origin IS NULL
        OR p_origin NOT IN ('pull', 'upload', 'verify')
        OR (p_feed IS NOT NULL AND (p_feed NOT IN ('IYS', 'HS') OR p_origin <> 'pull'))
        OR p_movements IS NULL OR jsonb_typeof(p_movements) <> 'array' THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-32';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM relay.iys_brands b
        WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = p_brand_id) THEN
        RETURN QUERY SELECT 'brand_not_found'::text, 0::bigint;
        RETURN;
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['iys_sync', p_brand_id::text]);
      INSERT INTO relay.iys_sync_states (tenant_id, environment, brand_id, stale_state,
        drift_count, address_count, address_state, created_at, updated_at)
      VALUES (v_tenant, v_env, p_brand_id, 'fresh', 0, 0, 'ok', p_now, p_now)
      ON CONFLICT (tenant_id, environment, brand_id) DO NOTHING;
      FOR v_movement IN SELECT m FROM jsonb_array_elements(p_movements) m LOOP
        IF v_movement->>'type' IS NULL OR v_movement->>'status' IS NULL
          OR v_movement->>'recipient_type' IS NULL OR v_movement->>'source' IS NULL
          OR v_movement->>'digest' IS NULL OR v_movement->>'digest_key_id' IS NULL
          OR (v_movement->>'digest_alt' IS NULL)
            <> (v_movement->>'digest_alt_key_id' IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-32';
        END IF;
        v_registered := (v_movement->>'registered_at')::timestamptz;
        v_digest := decode(v_movement->>'digest', 'hex');
        v_alt := decode(v_movement->>'digest_alt', 'hex');
        SELECT * INTO v_current FROM relay.iys_permissions p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.brand_id = p_brand_id
            AND p.consent_type = v_movement->>'type'
            AND p.recipient_type = v_movement->>'recipient_type'
            AND p.superseded_at IS NULL
            AND (p.address_digest = v_digest OR p.address_digest = v_alt
              OR p.address_digest_alt = v_digest OR p.address_digest_alt = v_alt)
          ORDER BY p.created_at DESC, p.id DESC
          LIMIT 1
          FOR UPDATE;
        IF v_current.id IS NOT NULL
          AND v_current.consent_status = v_movement->>'status'
          AND (v_current.transaction_ref IS NOT DISTINCT FROM v_movement->>'transaction_ref'
            OR p_origin = 'verify') THEN
          UPDATE relay.iys_permissions p SET verified_at = p_now,
              pulled_at = CASE WHEN p_origin = 'upload' THEN p.pulled_at ELSE p_now END
            WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.id = v_current.id;
        ELSIF v_current.id IS NOT NULL AND v_registered IS NOT NULL
          AND v_current.registered_at IS NOT NULL
          AND v_current.registered_at > v_registered THEN
          NULL;
        ELSE
          v_refusal := CASE WHEN p_origin IN ('pull', 'verify')
            AND v_movement->>'status' = 'RET'
            AND (v_current.id IS NULL OR v_current.consent_status <> 'RET')
            THEN 'pending' END;
          UPDATE relay.iys_permissions p SET superseded_at = p_now
            WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.brand_id = p_brand_id
              AND p.consent_type = v_movement->>'type'
              AND p.recipient_type = v_movement->>'recipient_type'
              AND p.superseded_at IS NULL
              AND (p.address_digest = v_digest OR p.address_digest = v_alt
                OR p.address_digest_alt = v_digest OR p.address_digest_alt = v_alt);
          INSERT INTO relay.iys_permissions (tenant_id, environment, id, brand_id,
            consent_type, address_digest, address_digest_key_id, address_digest_alt,
            address_digest_alt_key_id, recipient_type, consent_status, source, consent_at,
            registered_at, transaction_ref, origin, refusal_state, verified_at, pulled_at,
            superseded_at, created_at)
          VALUES (v_tenant, v_env, uuidv7(), p_brand_id, v_movement->>'type', v_digest,
            (v_movement->>'digest_key_id')::uuid, v_alt,
            (v_movement->>'digest_alt_key_id')::uuid, v_movement->>'recipient_type',
            v_movement->>'status', v_movement->>'source',
            (v_movement->>'consent_at')::timestamptz, v_registered,
            v_movement->>'transaction_ref', p_origin, v_refusal, p_now,
            CASE WHEN p_origin <> 'upload' THEN p_now END, NULL, p_now);
          v_applied := v_applied + 1;
        END IF;
      END LOOP;
      IF p_feed = 'IYS' THEN
        UPDATE relay.iys_sync_states s SET cursor_iys = COALESCE(p_cursor, s.cursor_iys),
            updated_at = p_now
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.brand_id = p_brand_id;
      ELSIF p_feed = 'HS' THEN
        UPDATE relay.iys_sync_states s SET cursor_hs = COALESCE(p_cursor, s.cursor_hs),
            updated_at = p_now
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.brand_id = p_brand_id;
      END IF;
      RETURN QUERY SELECT 'applied'::text, v_applied;
    END
    $fn$
    """
  end

  defp mark do
    ~S"""
    CREATE FUNCTION relay_fn.iys_permission_mark(p_permission_id uuid, p_mark text,
      p_now timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_row relay.iys_permissions;
    BEGIN
      IF p_permission_id IS NULL OR p_now IS NULL OR p_mark IS NULL
        OR p_mark NOT IN ('refusal_applied', 'refusal_unmatched', 'withdrawn') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-32';
      END IF;
      SELECT * INTO v_row FROM relay.iys_permissions p
        WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.id = p_permission_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF p_mark IN ('refusal_applied', 'refusal_unmatched') THEN
        UPDATE relay.iys_permissions p
          SET refusal_state = CASE p_mark WHEN 'refusal_applied' THEN 'applied'
            ELSE 'unmatched' END
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.id = p_permission_id
            AND p.refusal_state = 'pending';
        RETURN 'marked';
      END IF;
      UPDATE relay.iys_permissions p SET superseded_at = p_now
        WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.id = p_permission_id
          AND p.superseded_at IS NULL;
      RETURN 'marked';
    END
    $fn$
    """
  end

  defp record do
    ~S"""
    CREATE FUNCTION relay_fn.iys_sync_record(p_brand_id uuid, p_observation jsonb,
      p_now timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_pull text := p_observation->>'pull';
      v_full text := p_observation->>'full_sync';
    BEGIN
      IF p_brand_id IS NULL OR p_now IS NULL OR p_observation IS NULL
        OR jsonb_typeof(p_observation) <> 'object'
        OR (v_pull IS NOT NULL AND v_pull NOT IN ('ok', 'failed'))
        OR (v_pull = 'failed' AND p_observation->>'error_code' IS NULL)
        OR (v_full IS NOT NULL AND v_full NOT IN ('started', 'finished')) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-32';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM relay.iys_brands b
        WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = p_brand_id) THEN
        RETURN 'brand_not_found';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['iys_sync', p_brand_id::text]);
      INSERT INTO relay.iys_sync_states (tenant_id, environment, brand_id, stale_state,
        drift_count, address_count, address_state, created_at, updated_at)
      VALUES (v_tenant, v_env, p_brand_id, 'fresh', 0, 0, 'ok', p_now, p_now)
      ON CONFLICT (tenant_id, environment, brand_id) DO NOTHING;
      UPDATE relay.iys_sync_states s SET
          last_attempt_at = CASE WHEN v_pull IS NULL THEN s.last_attempt_at ELSE p_now END,
          last_pull_at = CASE WHEN v_pull = 'ok' THEN p_now ELSE s.last_pull_at END,
          last_error_code = CASE WHEN v_pull = 'ok' THEN NULL
            WHEN v_pull = 'failed' THEN left(p_observation->>'error_code', 64)
            ELSE s.last_error_code END,
          last_error_at = CASE WHEN v_pull = 'ok' THEN NULL WHEN v_pull = 'failed' THEN p_now
            ELSE s.last_error_at END,
          cursor_iys = CASE WHEN v_full = 'started' THEN NULL ELSE s.cursor_iys END,
          cursor_hs = CASE WHEN v_full = 'started' THEN NULL ELSE s.cursor_hs END,
          full_sync_started_at = CASE WHEN v_full = 'started' THEN p_now
            WHEN v_full = 'finished' THEN NULL ELSE s.full_sync_started_at END,
          full_sync_floor_at = CASE
            WHEN v_full = 'started' AND (p_observation->>'floor')::boolean IS TRUE THEN p_now
            ELSE s.full_sync_floor_at END,
          last_full_sync_at = CASE WHEN v_full = 'finished' THEN p_now
            ELSE s.last_full_sync_at END,
          stale_state = COALESCE(p_observation->>'stale_state', s.stale_state),
          reconciled_at = CASE WHEN p_observation ? 'drift_count' THEN p_now
            ELSE s.reconciled_at END,
          drift_count = COALESCE((p_observation->>'drift_count')::bigint, s.drift_count),
          address_count = COALESCE((p_observation->>'address_count')::bigint, s.address_count),
          address_state = COALESCE(p_observation->>'address_state', s.address_state),
          updated_at = p_now
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.brand_id = p_brand_id;
      RETURN 'recorded';
    END
    $fn$
    """
  end

  defp overview do
    ~S"""
    CREATE FUNCTION relay_ops.iys_sync_overview(p_now timestamptz, p_warning_s bigint,
      p_stop_s bigint)
      RETURNS TABLE (stale_warning bigint, stale_stopped bigint, address_warning bigint,
        address_reached bigint, drift bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT
        count(*) FILTER (WHERE x.age_s >= p_warning_s AND x.age_s < p_stop_s),
        count(*) FILTER (WHERE x.age_s >= p_stop_s),
        count(*) FILTER (WHERE x.address_state = 'warning'),
        count(*) FILTER (WHERE x.address_state = 'reached'),
        COALESCE(sum(x.drift_count), 0)::bigint
      FROM (SELECT extract(epoch FROM p_now - COALESCE(s.last_pull_at, b.created_at)) AS age_s,
          COALESCE(s.address_state, 'ok') AS address_state,
          COALESCE(s.drift_count, 0) AS drift_count
        FROM relay.iys_brands b
        JOIN relay.iys_configs c ON c.tenant_id = b.tenant_id AND c.environment = b.environment
        LEFT JOIN relay.iys_sync_states s ON s.tenant_id = b.tenant_id
          AND s.environment = b.environment AND s.brand_id = b.id
        WHERE b.state = 'active') x
    $fn$
    """
  end

  defp retry do
    ~S"""
    CREATE FUNCTION relay_fn.iys_upload_retry(p_upload_id uuid, p_reason text,
      p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text, p_now timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_upload relay.iys_uploads;
    BEGIN
      IF p_upload_id IS NULL OR p_record_digest IS NULL OR p_now IS NULL
        OR p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 1 AND 500 THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-34';
      END IF;
      SELECT * INTO v_upload FROM relay.iys_uploads u
        WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.id = p_upload_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_upload.state <> 'failed' THEN
        RETURN 'not_failed';
      END IF;
      IF v_upload.brand_id IS NULL OR v_upload.address_ct IS NULL THEN
        RETURN 'not_retryable';
      END IF;
      UPDATE relay.iys_uploads u SET state = 'pending', settled_at = NULL, attempts = 0,
          claimed_until = NULL, updated_at = p_now
        WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.id = p_upload_id;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'iys_upload.retried',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'iys_upload',
        p_upload_id::text, p_reason, p_record_digest);
      RETURN 'retried';
    END
    $fn$
    """
  end
end
