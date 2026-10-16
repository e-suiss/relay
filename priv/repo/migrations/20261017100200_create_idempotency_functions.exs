defmodule Relay.Repo.Migrations.CreateIdempotencyFunctions do
  use Ecto.Migration

  @functions [
    {"relay_private.idempotency_lock_key(text, text)", "relay_migrator", ~w(relay_owner)},
    {"relay_fn.idempotency_begin(text, text, bytea)", "relay_owner", ~w(relay_app)},
    {"relay_fn.idempotency_complete(text, text, bytea, smallint, jsonb, bytea, uuid)",
     "relay_owner", ~w(relay_app)}
  ]

  # OP-6
  # OP-68 (8)
  # API-11
  # API-13
  # API-14
  # INV-11
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
      CREATE FUNCTION relay_private.idempotency_lock_key(p_endpoint text, p_key text) RETURNS bigint
      LANGUAGE plpgsql STABLE
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      BEGIN
        IF p_endpoint IS NULL OR char_length(p_endpoint) NOT BETWEEN 1 AND 128
          OR p_key IS NULL OR char_length(p_key) NOT BETWEEN 8 AND 255 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-11';
        END IF;
        RETURN hashtextextended(relay_private.ctx_tenant_id()::text || '|'
          || relay_private.ctx_environment()::text || '|' || p_endpoint || '|' || p_key, 0);
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.idempotency_begin(p_endpoint text, p_key text, p_fingerprint bytea)
        RETURNS TABLE (result text, response_status smallint, response_headers jsonb,
          response_body_ct bytea, response_body_key_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_lock bigint := relay_private.idempotency_lock_key(p_endpoint, p_key);
        v_row relay.idempotency_keys;
      BEGIN
        IF p_fingerprint IS NULL OR octet_length(p_fingerprint) <> 32 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-13';
        END IF;
        IF NOT pg_try_advisory_xact_lock(v_lock) THEN
          RETURN QUERY SELECT 'in_progress'::text, NULL::smallint, NULL::jsonb, NULL::bytea, NULL::uuid;
          RETURN;
        END IF;
        SELECT * INTO v_row FROM relay.idempotency_keys k
          WHERE k.tenant_id = relay_private.ctx_tenant_id()
            AND k.environment = relay_private.ctx_environment()
            AND k.endpoint = p_endpoint
            AND k.key = p_key
            AND k.created_at > now() - interval '24 hours'
          ORDER BY k.created_at DESC
          LIMIT 1;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'created'::text, NULL::smallint, NULL::jsonb, NULL::bytea, NULL::uuid;
        ELSIF v_row.request_fingerprint = p_fingerprint THEN
          RETURN QUERY SELECT 'replayed'::text, v_row.response_status, v_row.response_headers,
            v_row.response_body_ct, v_row.response_body_key_id;
        ELSE
          RETURN QUERY SELECT 'conflict'::text, NULL::smallint, NULL::jsonb, NULL::bytea, NULL::uuid;
        END IF;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.idempotency_complete(p_endpoint text, p_key text, p_fingerprint bytea,
        p_response_status smallint, p_response_headers jsonb, p_response_body_ct bytea,
        p_response_body_key_id uuid) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_lock bigint := relay_private.idempotency_lock_key(p_endpoint, p_key);
        v_now timestamptz := now();
      BEGIN
        IF p_fingerprint IS NULL OR octet_length(p_fingerprint) <> 32
          OR p_response_status IS NULL OR p_response_status NOT BETWEEN 100 AND 599 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-14';
        END IF;
        IF p_response_status IN (400, 401, 403, 429) THEN
          RETURN 'not_cacheable';
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM pg_locks l
          WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid() AND l.granted
            AND l.mode = 'ExclusiveLock' AND l.objsubid = 1
            AND l.classid = ((v_lock >> 32) & 4294967295)::oid
            AND l.objid = (v_lock & 4294967295)::oid)
          OR EXISTS (
          SELECT 1 FROM relay.idempotency_keys k
          WHERE k.tenant_id = relay_private.ctx_tenant_id()
            AND k.environment = relay_private.ctx_environment()
            AND k.endpoint = p_endpoint
            AND k.key = p_key
            AND k.created_at > v_now - interval '24 hours') THEN
          RETURN 'not_claimed';
        END IF;
        INSERT INTO relay.idempotency_keys (tenant_id, environment, id, created_at, endpoint, key,
          request_fingerprint, expires_at, response_status, response_headers, response_body_ct,
          response_body_key_id)
        VALUES (relay_private.ctx_tenant_id(), relay_private.ctx_environment(), uuidv7(), v_now,
          p_endpoint, p_key, p_fingerprint, v_now + interval '24 hours', p_response_status,
          p_response_headers, p_response_body_ct, p_response_body_key_id);
        RETURN 'stored';
      END
      $fn$
      """
    ]
  end
end
