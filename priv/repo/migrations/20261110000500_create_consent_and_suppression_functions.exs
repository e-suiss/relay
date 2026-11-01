defmodule Relay.Repo.Migrations.CreateConsentAndSuppressionFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.consent_record(uuid, uuid, uuid, text, text, text, text, text, bigint, timestamptz, bytea, bytea, uuid, text, text, text)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.consent_current(uuid)", "relay_owner", ~w(relay_app relay_report)},
    {"relay_fn.suppression_add(uuid, text, bytea, uuid, bytea, text, timestamptz, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.suppression_lift(uuid, text, text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.suppression_match(text, bytea[])", "relay_owner", ~w(relay_app relay_report)}
  ]

  # PC-59 (1)
  # PC-59 (2)
  # PC-20
  # PC-21
  # E-80
  # OP-20
  # CH-40
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.consent_record(p_id uuid, p_recipient_id uuid,
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
          OR p_status NOT IN ('none', 'pending', 'active', 'revoked', 'expired')
          OR p_source IS NULL OR p_source_sequence IS NULL OR p_occurred_at IS NULL
          OR p_writer IS NULL OR p_writer NOT IN ('access', 'relay')
          OR (p_evidence_ct IS NULL) <> (p_evidence_key_id IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-59';
        END IF;
        IF p_status = 'active' AND (p_text_version_digest IS NULL OR p_evidence_ct IS NULL
          OR p_consent_kind IS NULL OR p_recipient_type IS NULL) THEN
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
      """,
      ~S"""
      CREATE FUNCTION relay_fn.consent_current(p_recipient_id uuid)
        RETURNS TABLE (brand_subtenant_id uuid, channel text, status text, consent_id uuid,
          consent_kind text, recipient_type text, source text, occurred_at timestamptz)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        WITH latest AS (
          SELECT DISTINCT ON (c.brand_subtenant_id, c.channel, c.source) c.*
          FROM relay.consents c
          WHERE c.tenant_id = relay_private.ctx_tenant_id()
            AND c.environment = relay_private.ctx_environment()
            AND c.recipient_id = p_recipient_id
          ORDER BY c.brand_subtenant_id, c.channel, c.source, c.source_sequence DESC
        )
        SELECT DISTINCT ON (l.brand_subtenant_id, l.channel) l.brand_subtenant_id,
          l.channel::text, l.status, l.id, l.consent_kind, l.recipient_type, l.source,
          l.occurred_at
        FROM latest l
        ORDER BY l.brand_subtenant_id, l.channel, (l.status = 'revoked') DESC,
          l.occurred_at DESC, l.id DESC
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.suppression_add(p_id uuid, p_channel text, p_target_digest bytea,
        p_target_digest_key_id uuid, p_target_digest_next bytea, p_reason text,
        p_expires_at timestamptz, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, suppression_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_existing uuid;
      BEGIN
        IF p_channel IS NULL OR p_target_digest IS NULL OR octet_length(p_target_digest) <> 32
          OR p_target_digest_key_id IS NULL OR p_reason IS NULL
          OR p_reason NOT IN ('hard_bounce', 'complaint', 'invalid', 'soft_bounce', 'manual')
          OR p_actor_ref IS NULL
          OR (p_reason = 'manual' AND p_record_digest IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-59';
        END IF;
        IF (p_reason = 'soft_bounce' AND (p_expires_at IS NULL OR p_expires_at <= now()))
          OR (p_reason = 'manual' AND p_expires_at IS NOT NULL AND p_expires_at <= now())
          OR (p_reason IN ('hard_bounce', 'complaint', 'invalid') AND p_expires_at IS NOT NULL) THEN
          RETURN QUERY SELECT 'invalid_expiry'::text, NULL::uuid;
          RETURN;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM relay.blind_index_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_target_digest_key_id
            AND k.state IN ('active', 'rotating')) THEN
          RETURN QUERY SELECT 'key_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['suppression', p_channel,
          encode(p_target_digest, 'hex')]);
        SELECT s.id INTO v_existing FROM relay.suppressions s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.channel = p_channel
            AND (s.target_digest = p_target_digest OR s.target_digest_next = p_target_digest)
            AND s.reason = p_reason AND s.lifted_at IS NULL
            AND (s.expires_at IS NULL OR s.expires_at > now())
          LIMIT 1;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_existing;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.suppressions (tenant_id, environment, id, channel, target_digest,
          target_digest_key_id, target_digest_next, reason, expires_at, created_by_ref,
          lifted_at, lifted_by_ref, lift_reason, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_channel, p_target_digest, p_target_digest_key_id,
          p_target_digest_next, p_reason, p_expires_at, p_actor_ref, NULL, NULL, NULL, now(),
          now());
        IF p_reason = 'manual' THEN
          PERFORM relay_private.audit_write(v_tenant, v_env::text, 'suppression.added',
            p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'suppression',
            p_id::text, p_reason, p_record_digest);
        END IF;
        RETURN QUERY SELECT 'added'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.suppression_lift(p_suppression_id uuid, p_lifter text,
        p_step_up_record_ref text, p_reason text, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.suppressions;
      BEGIN
        IF p_lifter IS NULL OR p_lifter NOT IN ('tenant', 'operator') OR p_reason IS NULL
          OR char_length(p_reason) NOT BETWEEN 1 AND 2000 OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'PC-59';
        END IF;
        SELECT * INTO v_row FROM relay.suppressions s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_suppression_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text;
          RETURN;
        END IF;
        IF v_row.lifted_at IS NOT NULL THEN
          RETURN QUERY SELECT 'already_lifted'::text;
          RETURN;
        END IF;
        IF p_lifter = 'tenant' AND v_row.reason NOT IN ('manual', 'invalid') THEN
          RETURN QUERY SELECT 'lift_forbidden'::text;
          RETURN;
        END IF;
        IF p_lifter = 'operator' AND v_row.reason NOT IN ('manual', 'invalid')
          AND p_step_up_record_ref IS NULL THEN
          RETURN QUERY SELECT 'step_up_required'::text;
          RETURN;
        END IF;
        UPDATE relay.suppressions s SET lifted_at = now(), lifted_by_ref = p_actor_ref,
            lift_reason = p_reason, updated_at = now()
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = v_row.id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'suppression.lifted',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'suppression',
          v_row.id::text, p_reason, p_record_digest);
        RETURN QUERY SELECT 'lifted'::text;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.suppression_match(p_channel text, p_digests bytea[])
        RETURNS TABLE (suppression_id uuid, reason text, expires_at timestamptz)
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT s.id, s.reason, s.expires_at
        FROM relay.suppressions s
        WHERE s.tenant_id = relay_private.ctx_tenant_id()
          AND s.environment = relay_private.ctx_environment()
          AND s.channel = p_channel AND s.lifted_at IS NULL
          AND (s.expires_at IS NULL OR s.expires_at > now())
          AND (s.target_digest = ANY (p_digests) OR s.target_digest_next = ANY (p_digests))
        ORDER BY s.created_at, s.id
      $fn$
      """
    ]
  end
end
