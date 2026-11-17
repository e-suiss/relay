defmodule Relay.Repo.Migrations.AddIysUploadAccessRecord do
  use Ecto.Migration

  # E-109
  # E-21
  # PC-30
  # OP-57
  def up do
    execute("ALTER TABLE relay.iys_uploads ADD COLUMN access_record uuid")
    execute("ALTER TABLE relay.iys_uploads ADD COLUMN access_environment uuid")

    execute(~S"""
    ALTER TABLE relay.iys_uploads ADD CONSTRAINT iys_uploads_access_record_check
      CHECK ((access_record IS NULL) = (access_environment IS NULL)
        AND (access_record IS NULL OR origin = 'access')) NOT VALID
    """)

    execute("SET LOCAL ROLE relay_owner")
    execute(enqueue())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp enqueue do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.iys_upload_enqueue(p_id uuid, p_upload jsonb,
      p_address_ct bytea, p_address_key_id uuid, p_address_digest bytea,
      p_address_digest_key_id uuid, p_now timestamptz)
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
      v_record uuid := (p_upload->>'access_record')::uuid;
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
            OR (v_record IS NOT NULL AND u.access_record = v_record)
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
        attempts, claimed_until, error_code, error_at, created_at, updated_at, settled_at,
        access_record, access_environment)
      VALUES (v_tenant, v_env, p_id, v_brand, v_type, v_status, p_upload->>'recipient_type',
        p_upload->>'source', p_upload->>'origin', (p_upload->>'consent_at')::timestamptz,
        (p_upload->>'recipient_id')::uuid, v_consent, p_address_ct, p_address_key_id,
        p_address_digest, p_address_digest_key_id,
        CASE WHEN v_brand IS NULL THEN 'failed' ELSE 'pending' END,
        (p_upload->>'deadline_at')::timestamptz, 0, NULL,
        CASE WHEN v_brand IS NULL THEN 'brand_not_mapped' END,
        CASE WHEN v_brand IS NULL THEN p_now END, p_now, p_now,
        CASE WHEN v_brand IS NULL THEN p_now END, v_record,
        (p_upload->>'access_environment')::uuid);
      IF v_brand IS NULL THEN
        RETURN QUERY SELECT 'brand_not_mapped'::text, p_id;
      ELSE
        RETURN QUERY SELECT 'queued'::text, p_id;
      END IF;
    END
    $fn$
    """
  end
end
