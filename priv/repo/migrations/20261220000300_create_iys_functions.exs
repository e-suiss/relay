defmodule Relay.Repo.Migrations.CreateIysFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @ts "timestamp with time zone"

  @functions [
    {"relay_fn.iys_config_put(uuid, jsonb, jsonb, bigint, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.iys_config_observe(jsonb, #{@ts})", "relay_owner", ~w(relay_app)},
    {"relay_fn.iys_brands_observe(jsonb, #{@ts})", "relay_owner", ~w(relay_app)},
    {"relay_fn.iys_upload_enqueue(uuid, jsonb, bytea, uuid, bytea, uuid, #{@ts})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.iys_upload_claim(uuid, #{@ts}, #{@ts})", "relay_owner", ~w(relay_app)},
    {"relay_fn.iys_upload_settle(uuid, text, jsonb, uuid, #{@ts})", "relay_owner", ~w(relay_app)},
    {"relay_ops.iys_scopes(integer)", "relay_maint", ~w(relay_worker)}
  ]

  # PC-28
  # PC-29
  # PC-30
  # PC-34
  # E-21
  # E-22
  # OP-8
  def up do
    Enum.each([put(), observe(), brands(), enqueue(), claim(), settle(), scopes()], &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp put do
    ~S"""
    CREATE FUNCTION relay_fn.iys_config_put(p_id uuid, p_config jsonb, p_brands jsonb,
      p_expected_version bigint, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
      p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_mode text := p_config->>'mode';
      v_api text := p_config->>'api';
      v_secret uuid := (p_config->>'credential_ref_id')::uuid;
      v_own boolean;
      v_config relay.iys_configs;
      v_version bigint;
      v_brand jsonb;
      v_subtenant uuid;
      v_sender uuid;
      v_code bigint;
    BEGIN
      IF p_id IS NULL OR p_config IS NULL OR jsonb_typeof(p_config) <> 'object'
        OR p_brands IS NULL OR jsonb_typeof(p_brands) <> 'array' OR p_record_digest IS NULL
        OR v_mode IS NULL OR v_mode NOT IN ('own', 'integrator')
        OR v_api IS NULL OR v_api NOT IN ('production', 'sandbox')
        OR p_config->>'iys_code' IS NULL OR p_config->>'username' IS NULL OR v_secret IS NULL
        OR (v_mode = 'integrator') <> (p_config->>'integrator_code' IS NOT NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-29';
      END IF;
      IF relay_private.tenant_status() <> 'active' THEN
        RETURN QUERY SELECT 'tenant_inactive'::text, NULL::bigint;
        RETURN;
      END IF;
      IF v_env = 'test' AND v_api <> 'sandbox' THEN
        RETURN QUERY SELECT 'sandbox_required'::text, NULL::bigint;
        RETURN;
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['iys_config']);
      IF NOT EXISTS (SELECT 1 FROM relay.secret_refs s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = v_secret
          AND s.kind = 'iys_credential' AND s.state = 'active') THEN
        RETURN QUERY SELECT 'secret_not_found'::text, NULL::bigint;
        RETURN;
      END IF;
      SELECT * INTO v_config FROM relay.iys_configs c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env
        FOR UPDATE;
      IF p_expected_version IS NOT NULL
        AND p_expected_version IS DISTINCT FROM COALESCE(v_config.version, 0) THEN
        RETURN QUERY SELECT 'version_conflict'::text, v_config.version;
        RETURN;
      END IF;
      IF (SELECT count(*) FROM jsonb_array_elements(p_brands) b)
          <> (SELECT count(DISTINCT b->>'brand_code') FROM jsonb_array_elements(p_brands) b)
        OR (SELECT count(*) FROM jsonb_array_elements(p_brands) b)
          <> (SELECT count(DISTINCT COALESCE(b->>'subtenant_id', '') || '/'
            || COALESCE(b->>'sender_identity_id', '')) FROM jsonb_array_elements(p_brands) b) THEN
        RETURN QUERY SELECT 'binding_conflict'::text, v_config.version;
        RETURN;
      END IF;
      FOR v_brand IN SELECT b FROM jsonb_array_elements(p_brands) b LOOP
        v_subtenant := (v_brand->>'subtenant_id')::uuid;
        v_sender := (v_brand->>'sender_identity_id')::uuid;
        v_code := (v_brand->>'brand_code')::bigint;
        IF v_code IS NULL OR v_brand->>'id' IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-29';
        END IF;
        IF v_subtenant IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = v_subtenant) THEN
          RETURN QUERY SELECT 'subtenant_not_found'::text, v_config.version;
          RETURN;
        END IF;
        IF v_sender IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.sender_identities i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = v_sender) THEN
          RETURN QUERY SELECT 'sender_identity_not_found'::text, v_config.version;
          RETURN;
        END IF;
        IF v_sender IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.sender_identities i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = v_sender
            AND i.registration->>'iys_brand_code' = v_code::text) THEN
          RETURN QUERY SELECT 'sender_identity_mismatch'::text, v_config.version;
          RETURN;
        END IF;
      END LOOP;
      v_own := v_mode = 'own';
      IF v_config.id IS NULL THEN
        PERFORM relay_private.assert_new_id(p_id);
        v_version := 1;
        INSERT INTO relay.iys_configs (tenant_id, environment, id, mode, api, iys_code,
          integrator_code, username, credential_ref_id, quota_state, version, created_at,
          updated_at)
        VALUES (v_tenant, v_env, p_id, v_mode, v_api, (p_config->>'iys_code')::bigint,
          (p_config->>'integrator_code')::bigint, p_config->>'username', v_secret, 'unknown',
          v_version, now(), now());
      ELSE
        v_version := v_config.version + 1;
        UPDATE relay.iys_configs c SET mode = v_mode, api = v_api,
            iys_code = (p_config->>'iys_code')::bigint,
            integrator_code = (p_config->>'integrator_code')::bigint,
            username = p_config->>'username', credential_ref_id = v_secret,
            blocked_code = NULL, blocked_at = NULL, version = v_version, updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_config.id;
      END IF;
      UPDATE relay.iys_brands b SET state = 'archived', archived_at = now(), updated_at = now()
        WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.state = 'active';
      FOR v_brand IN SELECT b FROM jsonb_array_elements(p_brands) b LOOP
        v_code := (v_brand->>'brand_code')::bigint;
        UPDATE relay.iys_brands b SET state = 'active', archived_at = NULL,
            name = v_brand->>'name', subtenant_id = (v_brand->>'subtenant_id')::uuid,
            sender_identity_id = (v_brand->>'sender_identity_id')::uuid,
            message_access = CASE WHEN v_own THEN 'write' WHEN v_config.mode = 'integrator'
              THEN b.message_access ELSE 'unknown' END,
            call_access = CASE WHEN v_own THEN 'write' WHEN v_config.mode = 'integrator'
              THEN b.call_access ELSE 'unknown' END,
            email_access = CASE WHEN v_own THEN 'write' WHEN v_config.mode = 'integrator'
              THEN b.email_access ELSE 'unknown' END,
            authorised_at = CASE WHEN v_own THEN now() WHEN v_config.mode = 'integrator'
              THEN b.authorised_at ELSE NULL END,
            updated_at = now()
          WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.brand_code = v_code;
        IF NOT FOUND THEN
          PERFORM relay_private.assert_new_id((v_brand->>'id')::uuid);
          INSERT INTO relay.iys_brands (tenant_id, environment, id, brand_code, name,
            subtenant_id, sender_identity_id, state, message_access, call_access, email_access,
            authorised_at, archived_at, created_at, updated_at)
          VALUES (v_tenant, v_env, (v_brand->>'id')::uuid, v_code, v_brand->>'name',
            (v_brand->>'subtenant_id')::uuid, (v_brand->>'sender_identity_id')::uuid, 'active',
            CASE WHEN v_own THEN 'write' ELSE 'unknown' END,
            CASE WHEN v_own THEN 'write' ELSE 'unknown' END,
            CASE WHEN v_own THEN 'write' ELSE 'unknown' END,
            CASE WHEN v_own THEN now() ELSE NULL END, NULL, now(), now());
        END IF;
      END LOOP;
      PERFORM relay_private.audit_write(v_tenant, v_env::text, 'iys_config.replaced',
        p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'iys_config',
        COALESCE(v_config.id, p_id)::text, NULL, p_record_digest);
      IF v_config.id IS NULL THEN
        RETURN QUERY SELECT 'created'::text, v_version;
      ELSE
        RETURN QUERY SELECT 'updated'::text, v_version;
      END IF;
    END
    $fn$
    """
  end

  defp observe do
    ~S"""
    CREATE FUNCTION relay_fn.iys_config_observe(p_observation jsonb, p_now timestamptz)
      RETURNS TABLE (result text, quota_state text)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_config relay.iys_configs;
    BEGIN
      IF p_observation IS NULL OR jsonb_typeof(p_observation) <> 'object' OR p_now IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-34';
      END IF;
      SELECT * INTO v_config FROM relay.iys_configs c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::text;
        RETURN;
      END IF;
      IF p_observation ? 'quota_state' THEN
        UPDATE relay.iys_configs c SET quota_state = p_observation->>'quota_state',
            consent_limit = (p_observation->>'consent_limit')::bigint,
            used_consent_limit = (p_observation->>'used_consent_limit')::bigint,
            consent_limit_exceed = (p_observation->>'consent_limit_exceed')::boolean,
            quota_checked_at = p_now, updated_at = p_now
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_config.id;
      END IF;
      IF p_observation ? 'blocked_code' THEN
        UPDATE relay.iys_configs c SET blocked_code = p_observation->>'blocked_code',
            blocked_at = CASE WHEN p_observation->>'blocked_code' IS NULL THEN NULL
              ELSE p_now END,
            updated_at = p_now
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_config.id;
      END IF;
      RETURN QUERY SELECT 'observed'::text, v_config.quota_state;
    END
    $fn$
    """
  end

  defp brands do
    ~S"""
    CREATE FUNCTION relay_fn.iys_brands_observe(p_brands jsonb, p_now timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
    BEGIN
      IF p_brands IS NULL OR jsonb_typeof(p_brands) <> 'array' OR p_now IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-29';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM relay.iys_configs c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.mode = 'integrator') THEN
        RETURN 'not_integrator';
      END IF;
      UPDATE relay.iys_brands b SET
          message_access = COALESCE(o.item->>'message_access', 'none'),
          call_access = COALESCE(o.item->>'call_access', 'none'),
          email_access = COALESCE(o.item->>'email_access', 'none'),
          authorised_at = p_now, updated_at = p_now
        FROM (SELECT x.brand_code, (SELECT e FROM jsonb_array_elements(p_brands) e
            WHERE (e->>'brand_code')::bigint = x.brand_code LIMIT 1) AS item
          FROM relay.iys_brands x
          WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.state = 'active') o
        WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.state = 'active'
          AND b.brand_code = o.brand_code;
      RETURN 'observed';
    END
    $fn$
    """
  end

  defp enqueue do
    ~S"""
    CREATE FUNCTION relay_fn.iys_upload_enqueue(p_id uuid, p_upload jsonb, p_address_ct bytea,
      p_address_key_id uuid, p_address_digest bytea, p_address_digest_key_id uuid,
      p_now timestamptz)
      RETURNS TABLE (result text, upload_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_type text := p_upload->>'consent_type';
      v_status text := p_upload->>'consent_status';
      v_consent uuid := (p_upload->>'consent_id')::uuid;
      v_brand uuid;
      v_existing uuid;
    BEGIN
      IF p_id IS NULL OR p_upload IS NULL OR jsonb_typeof(p_upload) <> 'object'
        OR v_type IS NULL OR v_status IS NULL OR p_address_digest IS NULL
        OR p_address_digest_key_id IS NULL OR p_now IS NULL
        OR (p_address_ct IS NULL) <> (p_address_key_id IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-30';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM relay.iys_configs c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env) THEN
        RETURN QUERY SELECT 'not_configured'::text, NULL::uuid;
        RETURN;
      END IF;
      IF p_upload ? 'brand_code' THEN
        SELECT b.id INTO v_brand FROM relay.iys_brands b
          WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.state = 'active'
            AND b.brand_code = (p_upload->>'brand_code')::bigint;
      ELSE
        SELECT b.id INTO v_brand FROM relay.iys_brands b
          WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.state = 'active'
            AND b.sender_identity_id IS NULL
            AND b.subtenant_id IS NOT DISTINCT FROM (p_upload->>'brand_subtenant_id')::uuid;
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['iys_upload', COALESCE(v_brand::text, ''), v_type,
        encode(p_address_digest, 'hex')]);
      SELECT u.id INTO v_existing FROM relay.iys_uploads u
        WHERE u.tenant_id = v_tenant AND u.environment = v_env
          AND (u.id = p_id OR (v_consent IS NOT NULL AND u.consent_id = v_consent)
            OR (v_status = 'RET' AND u.consent_status = 'RET'
              AND u.brand_id IS NOT DISTINCT FROM v_brand AND u.consent_type = v_type
              AND u.address_digest = p_address_digest AND u.state IN ('pending', 'uploaded')))
        ORDER BY u.id
        LIMIT 1;
      IF FOUND THEN
        RETURN QUERY SELECT 'duplicate'::text, v_existing;
        RETURN;
      END IF;
      IF v_status = 'RET' AND v_brand IS NOT NULL THEN
        UPDATE relay.iys_uploads u SET state = 'skipped', settled_at = p_now,
            error_code = 'superseded', error_at = p_now, address_ct = NULL,
            address_key_id = NULL, claimed_until = NULL, updated_at = p_now
          WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.brand_id = v_brand
            AND u.consent_type = v_type AND u.address_digest = p_address_digest
            AND u.consent_status = 'ONAY' AND u.state = 'pending';
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.iys_uploads (tenant_id, environment, id, brand_id, consent_type,
        consent_status, recipient_type, source, origin, consent_at, recipient_id, consent_id,
        address_ct, address_key_id, address_digest, address_digest_key_id, state, deadline_at,
        attempts, claimed_until, error_code, error_at, created_at, updated_at, settled_at)
      VALUES (v_tenant, v_env, p_id, v_brand, v_type, v_status, p_upload->>'recipient_type',
        p_upload->>'source', p_upload->>'origin', (p_upload->>'consent_at')::timestamptz,
        (p_upload->>'recipient_id')::uuid, v_consent, p_address_ct, p_address_key_id,
        p_address_digest, p_address_digest_key_id,
        CASE WHEN v_brand IS NULL THEN 'failed' ELSE 'pending' END,
        (p_upload->>'deadline_at')::timestamptz, 0, NULL,
        CASE WHEN v_brand IS NULL THEN 'brand_not_mapped' END,
        CASE WHEN v_brand IS NULL THEN p_now END, p_now, p_now,
        CASE WHEN v_brand IS NULL THEN p_now END);
      IF v_brand IS NULL THEN
        RETURN QUERY SELECT 'brand_not_mapped'::text, p_id;
      ELSE
        RETURN QUERY SELECT 'queued'::text, p_id;
      END IF;
    END
    $fn$
    """
  end

  defp claim do
    ~S"""
    CREATE FUNCTION relay_fn.iys_upload_claim(p_upload_id uuid, p_claimed_until timestamptz,
      p_now timestamptz)
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
      IF p_upload_id IS NULL OR p_claimed_until IS NULL OR p_now IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-30';
      END IF;
      SELECT * INTO v_upload FROM relay.iys_uploads u
        WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.id = p_upload_id;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['iys_upload', COALESCE(v_upload.brand_id::text, ''),
        v_upload.consent_type, encode(v_upload.address_digest, 'hex')]);
      SELECT * INTO v_upload FROM relay.iys_uploads u
        WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.id = p_upload_id
        FOR UPDATE;
      IF v_upload.state NOT IN ('pending', 'uploaded') THEN
        RETURN 'settled';
      END IF;
      IF v_upload.state = 'pending' AND v_upload.deadline_at IS NOT NULL
        AND v_upload.deadline_at <= p_now THEN
        RETURN 'overdue';
      END IF;
      IF v_upload.claimed_until IS NOT NULL AND v_upload.claimed_until > p_now THEN
        RETURN 'busy';
      END IF;
      IF EXISTS (SELECT 1 FROM relay.iys_uploads o
        WHERE o.tenant_id = v_tenant AND o.environment = v_env
          AND o.brand_id = v_upload.brand_id AND o.consent_type = v_upload.consent_type
          AND o.address_digest = v_upload.address_digest AND o.id <> v_upload.id
          AND ((o.state IN ('pending', 'uploaded') AND o.id < v_upload.id)
            OR (o.registered_at IS NOT NULL AND o.updated_at > p_now - interval '2 seconds')))
      THEN
        RETURN 'busy';
      END IF;
      UPDATE relay.iys_uploads u SET claimed_until = p_claimed_until,
          attempts = u.attempts + 1, updated_at = p_now
        WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.id = p_upload_id;
      RETURN 'claimed';
    END
    $fn$
    """
  end

  defp settle do
    ~S"""
    CREATE FUNCTION relay_fn.iys_upload_settle(p_upload_id uuid, p_outcome text, p_detail jsonb,
      p_consent_row_id uuid, p_now timestamptz)
      RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_upload relay.iys_uploads;
      v_subtenant uuid;
      v_channel text;
      v_status text;
      v_ref text;
      v_registered timestamptz;
      v_sequence bigint;
    BEGIN
      IF p_upload_id IS NULL OR p_outcome IS NULL OR p_now IS NULL
        OR p_outcome NOT IN ('retry', 'uploaded', 'confirmed', 'failed', 'expired', 'skipped')
        OR p_detail IS NULL OR jsonb_typeof(p_detail) <> 'object'
        OR (p_outcome = 'failed' AND p_detail->>'error_code' IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-30';
      END IF;
      SELECT * INTO v_upload FROM relay.iys_uploads u
        WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.id = p_upload_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN 'not_found';
      END IF;
      IF v_upload.state NOT IN ('pending', 'uploaded') THEN
        RETURN 'already_settled';
      END IF;
      v_ref := COALESCE(p_detail->>'transaction_ref', v_upload.transaction_ref);
      v_registered := COALESCE((p_detail->>'registered_at')::timestamptz,
        v_upload.registered_at);
      IF p_outcome = 'retry' THEN
        UPDATE relay.iys_uploads u SET claimed_until = NULL,
            state = CASE WHEN p_detail->>'state' = 'pending' THEN 'pending' ELSE u.state END,
            error_code = COALESCE(p_detail->>'error_code', u.error_code),
            error_at = CASE WHEN p_detail->>'error_code' IS NULL THEN u.error_at ELSE p_now END,
            trace_ref = COALESCE(p_detail->>'trace_ref', u.trace_ref), updated_at = p_now
          WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.id = p_upload_id;
        RETURN 'settled';
      END IF;
      IF p_outcome = 'uploaded' THEN
        UPDATE relay.iys_uploads u SET state = 'uploaded', claimed_until = NULL,
            transaction_ref = v_ref, registered_at = v_registered,
            trace_ref = COALESCE(p_detail->>'trace_ref', u.trace_ref), updated_at = p_now
          WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.id = p_upload_id;
        RETURN 'settled';
      END IF;
      UPDATE relay.iys_uploads u SET state = p_outcome, claimed_until = NULL, settled_at = p_now,
          transaction_ref = v_ref, registered_at = v_registered,
          error_code = COALESCE(p_detail->>'error_code', u.error_code),
          error_at = CASE WHEN p_detail->>'error_code' IS NULL THEN u.error_at ELSE p_now END,
          trace_ref = COALESCE(p_detail->>'trace_ref', u.trace_ref),
          address_ct = CASE WHEN p_outcome = 'failed' THEN u.address_ct END,
          address_key_id = CASE WHEN p_outcome = 'failed' THEN u.address_key_id END,
          updated_at = p_now
        WHERE u.tenant_id = v_tenant AND u.environment = v_env AND u.id = p_upload_id;
      IF v_upload.recipient_id IS NULL OR p_consent_row_id IS NULL
        OR p_outcome NOT IN ('confirmed', 'expired')
        OR (p_outcome = 'expired' AND v_upload.consent_status <> 'ONAY') THEN
        RETURN 'settled';
      END IF;
      v_status := CASE WHEN p_outcome = 'expired' THEN 'expired'
        WHEN v_upload.consent_status = 'ONAY' THEN 'active' ELSE 'revoked' END;
      IF v_status = 'active' AND NOT EXISTS (SELECT 1 FROM relay.consents c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = v_upload.consent_id
          AND c.text_version_digest IS NOT NULL AND c.evidence_ct IS NOT NULL
          AND c.consent_kind IS NOT NULL AND c.recipient_type IS NOT NULL) THEN
        RETURN 'settled';
      END IF;
      SELECT b.subtenant_id INTO v_subtenant FROM relay.iys_brands b
        WHERE b.tenant_id = v_tenant AND b.environment = v_env AND b.id = v_upload.brand_id;
      v_channel := CASE v_upload.consent_type WHEN 'MESAJ' THEN 'sms' WHEN 'ARAMA' THEN 'voice'
        ELSE 'email' END;
      PERFORM relay_private.lock_scope(ARRAY['consent', v_upload.recipient_id::text,
        COALESCE(v_subtenant::text, ''), v_channel, 'iys']);
      SELECT COALESCE(max(c.source_sequence), -1) + 1 INTO v_sequence FROM relay.consents c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env
          AND c.recipient_id = v_upload.recipient_id
          AND c.brand_subtenant_id IS NOT DISTINCT FROM v_subtenant
          AND c.channel::text = v_channel AND c.source = 'iys';
      PERFORM relay_private.assert_new_id(p_consent_row_id);
      INSERT INTO relay.consents (tenant_id, environment, id, recipient_id, brand_subtenant_id,
        channel, status, consent_kind, recipient_type, source, source_sequence, occurred_at,
        text_version_digest, evidence_ct, evidence_key_id, iys_transaction_ref, writer,
        source_event_ref, created_at)
      SELECT v_tenant, v_env, p_consent_row_id, v_upload.recipient_id, v_subtenant,
        v_channel::relay.channel, v_status, c.consent_kind,
        CASE v_upload.recipient_type WHEN 'TACIR' THEN 'merchant' ELSE 'individual' END, 'iys',
        v_sequence, CASE WHEN v_status = 'expired' THEN p_now ELSE COALESCE(v_registered, p_now)
          END,
        c.text_version_digest, c.evidence_ct, c.evidence_key_id, v_ref, 'relay', NULL, p_now
      FROM (SELECT 1) one
      LEFT JOIN relay.consents c ON c.tenant_id = v_tenant AND c.environment = v_env
        AND c.id = v_upload.consent_id;
      RETURN 'settled';
    END
    $fn$
    """
  end

  defp scopes do
    ~S"""
    CREATE FUNCTION relay_ops.iys_scopes(p_limit integer)
      RETURNS TABLE (tenant_id uuid, environment text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT c.tenant_id, c.environment::text
      FROM relay.iys_configs c
      ORDER BY c.tenant_id, c.environment
      LIMIT GREATEST(COALESCE(p_limit, 1000), 1)
    $fn$
    """
  end
end
