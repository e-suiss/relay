defmodule Relay.Repo.Migrations.AllowPendingIysConsents do
  use Ecto.Migration

  # PC-30
  # PC-21
  # E-21
  # OP-57
  def up do
    execute("ALTER TABLE relay.consents DROP CONSTRAINT consents_status_check")

    execute("""
    ALTER TABLE relay.consents ADD CONSTRAINT consents_status_check
      CHECK (status IN ('none', 'pending', 'pending_iys', 'active', 'revoked', 'expired'))
      NOT VALID
    """)

    execute("SET LOCAL ROLE relay_owner")
    execute(record())
    execute("RESET ROLE")
  end

  def down, do: :ok

  defp record do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.consent_record(p_id uuid, p_recipient_id uuid,
      p_brand_subtenant_id uuid, p_channel text, p_status text, p_consent_kind text,
      p_recipient_type text, p_source text, p_source_sequence bigint,
      p_occurred_at timestamptz, p_text_version_digest bytea, p_evidence_ct bytea,
      p_evidence_key_id uuid, p_iys_transaction_ref text, p_writer text,
      p_source_event_ref text)
      RETURNS TABLE (result text, consent_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_latest relay.consents;
    BEGIN
      IF p_channel IS NULL OR p_status IS NULL
        OR p_status NOT IN ('none', 'pending', 'pending_iys', 'active', 'revoked', 'expired')
        OR p_source IS NULL OR p_source_sequence IS NULL OR p_occurred_at IS NULL
        OR p_writer IS NULL OR p_writer NOT IN ('access', 'relay')
        OR (p_evidence_ct IS NULL) <> (p_evidence_key_id IS NULL) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-59';
      END IF;
      IF p_status IN ('active', 'pending_iys') AND (p_text_version_digest IS NULL
        OR p_evidence_ct IS NULL OR p_consent_kind IS NULL OR p_recipient_type IS NULL) THEN
        RETURN QUERY SELECT 'evidence_required'::text, NULL::uuid;
        RETURN;
      END IF;
      PERFORM 1 FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      IF p_brand_subtenant_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
        WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_brand_subtenant_id) THEN
        RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      IF p_evidence_key_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subject_keys k
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_evidence_key_id
          AND k.recipient_id = p_recipient_id AND k.retention_class = 'commercial_consent'
          AND k.state = 'active') THEN
        RETURN QUERY SELECT 'evidence_key_invalid'::text, NULL::uuid;
        RETURN;
      END IF;
      PERFORM relay_private.lock_scope(ARRAY['consent', p_recipient_id::text,
        COALESCE(p_brand_subtenant_id::text, ''), p_channel, p_source]);
      SELECT * INTO v_latest FROM relay.consents c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env
          AND c.recipient_id = p_recipient_id
          AND c.brand_subtenant_id IS NOT DISTINCT FROM p_brand_subtenant_id
          AND c.channel = p_channel AND c.source = p_source
        ORDER BY c.source_sequence DESC
        LIMIT 1;
      IF FOUND AND v_latest.source_sequence = p_source_sequence THEN
        RETURN QUERY SELECT 'duplicate'::text, v_latest.id;
        RETURN;
      END IF;
      IF FOUND AND v_latest.source_sequence > p_source_sequence THEN
        RETURN QUERY SELECT 'stale'::text, v_latest.id;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      INSERT INTO relay.consents (tenant_id, environment, id, recipient_id, brand_subtenant_id,
        channel, status, consent_kind, recipient_type, source, source_sequence, occurred_at,
        text_version_digest, evidence_ct, evidence_key_id, iys_transaction_ref, writer,
        source_event_ref, created_at)
      VALUES (v_tenant, v_env, p_id, p_recipient_id, p_brand_subtenant_id, p_channel, p_status,
        p_consent_kind, p_recipient_type, p_source, p_source_sequence, p_occurred_at,
        p_text_version_digest, p_evidence_ct, p_evidence_key_id, p_iys_transaction_ref,
        p_writer, p_source_event_ref, now());
      RETURN QUERY SELECT 'recorded'::text, p_id;
    END
    $fn$
    """
  end
end
