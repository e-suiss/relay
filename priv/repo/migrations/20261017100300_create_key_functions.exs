defmodule Relay.Repo.Migrations.CreateKeyFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.recipient_create(uuid, text, bytea, uuid, bytea, uuid, bytea, uuid)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.subject_key_create(uuid, uuid, text, bytea, uuid)", "relay_owner", ~w(relay_app)},
    {"relay_fn.tenant_key_register(uuid, text, date, text, bytea, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.tenant_key_destroy(uuid, text, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.blind_index_key_register(uuid, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.blind_index_key_rotate(uuid, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.secret_ref_register(uuid, text, text, bytea, uuid, bigint, bytea, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.secret_ref_retire(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.legal_hold_place(uuid, text, uuid, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.legal_hold_release(uuid, bytea, #{@actor})", "relay_owner", ~w(relay_app)}
  ]

  # OP-8
  # OP-17
  # OP-18
  # OP-26
  # TN-26
  # TN-27
  # TN-33
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
      CREATE FUNCTION relay_fn.recipient_create(p_id uuid, p_kind text, p_external_id_bidx bytea,
        p_bidx_key_id uuid, p_external_id_ct bytea, p_profile_dek_id uuid,
        p_profile_wrapped_dek bytea, p_wrapping_key_id uuid)
        RETURNS TABLE (result text, recipient_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_inserted uuid;
        v_existing uuid;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        PERFORM relay_private.assert_new_id(p_profile_dek_id);
        IF p_kind IS NULL OR p_kind NOT IN ('subscriber', 'agent') OR p_external_id_ct IS NULL
          OR p_profile_wrapped_dek IS NULL OR p_wrapping_key_id IS NULL
          OR (p_external_id_bidx IS NULL) <> (p_bidx_key_id IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-20';
        END IF;
        IF p_external_id_bidx IS NOT NULL THEN
          PERFORM relay_private.lock_scope(ARRAY['recipient', encode(p_external_id_bidx, 'hex')]);
          SELECT r.id INTO v_existing FROM relay.recipients r
            WHERE r.tenant_id = v_tenant AND r.environment = v_env
              AND r.external_id_bidx = p_external_id_bidx;
          IF FOUND THEN
            RETURN QUERY SELECT 'exists'::text, v_existing;
            RETURN;
          END IF;
        END IF;
        INSERT INTO relay.recipients AS r (tenant_id, environment, id, kind, external_id_bidx,
          external_id_bidx_key_id, external_id_bidx_next, external_id_ct, external_id_key_id, state,
          deleted_at, deleted_reason, created_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_kind, p_external_id_bidx, p_bidx_key_id, NULL,
          p_external_id_ct, p_profile_dek_id, 'active', NULL, NULL, now(), now())
        RETURNING r.id INTO v_inserted;
        INSERT INTO relay.subject_keys (tenant_id, environment, id, recipient_id, retention_class,
          wrapped_dek, wrapping_key_id, state, restricted_at, destroyed_at, destroy_reason, created_at)
        VALUES (v_tenant, v_env, p_profile_dek_id, p_id, 'recipient_profile', p_profile_wrapped_dek,
          p_wrapping_key_id, 'active', NULL, NULL, NULL, now());
        RETURN QUERY SELECT 'created'::text, v_inserted;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.subject_key_create(p_id uuid, p_recipient_id uuid,
        p_retention_class text, p_wrapped_dek bytea, p_wrapping_key_id uuid)
        RETURNS TABLE (result text, subject_key_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_state text;
        v_existing uuid;
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_retention_class IS NULL OR p_wrapped_dek IS NULL OR p_wrapping_key_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-18';
        END IF;
        SELECT r.state INTO v_state FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          FOR SHARE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        IF v_state = 'deleted' THEN
          RETURN QUERY SELECT 'recipient_deleted'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['subject_key', p_recipient_id::text, p_retention_class]);
        SELECT k.id INTO v_existing FROM relay.subject_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env
            AND k.recipient_id = p_recipient_id AND k.retention_class = p_retention_class;
        IF FOUND THEN
          RETURN QUERY SELECT 'exists'::text, v_existing;
          RETURN;
        END IF;
        INSERT INTO relay.subject_keys (tenant_id, environment, id, recipient_id, retention_class,
          wrapped_dek, wrapping_key_id, state, restricted_at, destroyed_at, destroy_reason, created_at)
        VALUES (v_tenant, v_env, p_id, p_recipient_id, p_retention_class, p_wrapped_dek,
          p_wrapping_key_id, 'active', NULL, NULL, NULL, now());
        RETURN QUERY SELECT 'created'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.tenant_key_register(p_id uuid, p_purpose text, p_valid_day date,
        p_kek_ref text, p_wrapped_key bytea, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        IF p_purpose IS NULL OR p_purpose NOT IN ('data', 'dek_wrap', 'receipt_day')
          OR (p_purpose = 'receipt_day') <> (p_valid_day IS NOT NULL)
          OR p_kek_ref IS NULL OR p_wrapped_key IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-27';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['tenant_key', p_purpose]);
        IF EXISTS (SELECT 1 FROM relay.tenant_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_id) THEN
          RETURN 'exists';
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        IF EXISTS (SELECT 1 FROM relay.tenant_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.purpose = p_purpose
            AND ((p_purpose <> 'receipt_day' AND k.state = 'active')
              OR (p_purpose = 'receipt_day' AND k.valid_day = p_valid_day))) THEN
          RETURN 'active_exists';
        END IF;
        INSERT INTO relay.tenant_keys (tenant_id, environment, id, purpose, valid_day, kek_ref,
          wrapped_key, state, destroyed_at, created_at)
        VALUES (v_tenant, v_env, p_id, p_purpose, p_valid_day, p_kek_ref, p_wrapped_key, 'active',
          NULL, now());
        PERFORM relay_private.audit_write(v_tenant, v_env, 'tenant_key.registered', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant_key', p_id::text, NULL,
          p_record_digest);
        RETURN 'created';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.tenant_key_destroy(p_key_id uuid, p_reason text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_key relay.tenant_keys;
      BEGIN
        SELECT * INTO v_key FROM relay.tenant_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_key_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_key.state = 'destroyed' THEN
          RETURN 'already_destroyed';
        END IF;
        IF EXISTS (SELECT 1 FROM relay.legal_holds h
          WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.scope = 'tenant'
            AND h.state = 'active') THEN
          RETURN 'held';
        END IF;
        IF (v_key.purpose IN ('data', 'dek_wrap') AND relay_private.tenant_status() <> 'closed')
          OR (v_key.purpose = 'receipt_day' AND now() < (v_key.valid_day + 8)::timestamptz) THEN
          RETURN 'not_allowed';
        END IF;
        UPDATE relay.tenant_keys k SET wrapped_key = NULL, state = 'destroyed', destroyed_at = now()
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_key_id;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'tenant_key.destroyed', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'tenant_key', p_key_id::text,
          p_reason, p_record_digest);
        RETURN 'destroyed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.blind_index_key_register(p_id uuid, p_hsm_ref text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        IF p_hsm_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-33';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['blind_index_key']);
        IF EXISTS (SELECT 1 FROM relay.blind_index_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.id = p_id) THEN
          RETURN 'exists';
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        IF EXISTS (SELECT 1 FROM relay.blind_index_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.state IN ('active', 'rotating')) THEN
          RETURN 'active_exists';
        END IF;
        INSERT INTO relay.blind_index_keys (tenant_id, environment, id, hsm_ref, state, created_at,
          retired_at)
        VALUES (v_tenant, v_env, p_id, p_hsm_ref, 'active', now(), NULL);
        PERFORM relay_private.audit_write(v_tenant, v_env, 'blind_index_key.registered',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'blind_index_key',
          p_id::text, NULL, p_record_digest);
        RETURN 'created';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.blind_index_key_rotate(p_new_id uuid, p_hsm_ref text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_rotating uuid;
      BEGIN
        IF p_hsm_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-33';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['blind_index_key']);
        IF NOT EXISTS (SELECT 1 FROM relay.blind_index_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.state = 'active') THEN
          RETURN 'not_active';
        END IF;
        SELECT k.id INTO v_rotating FROM relay.blind_index_keys k
          WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.state = 'rotating';
        IF FOUND THEN
          IF v_rotating = p_new_id THEN
            RETURN 'rotating';
          END IF;
          RAISE EXCEPTION 'invariant_violation' USING HINT = 'TN-33';
        END IF;
        PERFORM relay_private.assert_new_id(p_new_id);
        INSERT INTO relay.blind_index_keys (tenant_id, environment, id, hsm_ref, state, created_at,
          retired_at)
        VALUES (v_tenant, v_env, p_new_id, p_hsm_ref, 'rotating', now(), NULL);
        PERFORM relay_private.audit_write(v_tenant, v_env, 'blind_index_key.rotation_started',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'blind_index_key',
          p_new_id::text, NULL, p_record_digest);
        RETURN 'rotating';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.secret_ref_register(p_id uuid, p_kind text, p_ref text,
        p_secret_ct bytea, p_secret_key_id uuid, p_ref_version bigint, p_fingerprint bytea,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        IF p_kind IS NULL OR p_kind NOT IN ('provider_credential', 'channel_identity', 'webhook_signing')
          OR (p_ref IS NULL) = (p_secret_ct IS NULL)
          OR (p_secret_ct IS NULL) <> (p_secret_key_id IS NULL)
          OR p_ref ~ '://[^/]*:[^@/]*@'
          OR p_ref_version IS NULL
          OR p_fingerprint IS NULL OR octet_length(p_fingerprint) <> 32 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-26';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['secret_ref', p_kind, encode(p_fingerprint, 'hex')]);
        IF EXISTS (SELECT 1 FROM relay.secret_refs s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env
            AND (s.id = p_id OR (s.kind = p_kind AND s.fingerprint = p_fingerprint))) THEN
          RETURN 'exists';
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.secret_refs (tenant_id, environment, id, kind, ref, secret_ct,
          secret_key_id, ref_version, fingerprint, state, created_at, retired_at)
        VALUES (v_tenant, v_env, p_id, p_kind, p_ref, p_secret_ct, p_secret_key_id, p_ref_version,
          p_fingerprint, 'active', now(), NULL);
        PERFORM relay_private.audit_write(v_tenant, v_env, 'secret_ref.registered', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'secret_ref', p_id::text, NULL,
          p_record_digest);
        RETURN 'created';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.secret_ref_retire(p_id uuid, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
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
        SELECT s.state INTO v_state FROM relay.secret_refs s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state = 'retired' THEN
          RETURN 'already_retired';
        END IF;
        UPDATE relay.secret_refs s SET state = 'retired', retired_at = now()
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'secret_ref.retired', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'secret_ref', p_id::text, NULL,
          p_record_digest);
        RETURN 'retired';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.legal_hold_place(p_id uuid, p_scope text, p_recipient_id uuid,
        p_reason text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        PERFORM relay_private.assert_new_id(p_id);
        IF p_scope IS NULL OR p_scope NOT IN ('tenant', 'recipient')
          OR (p_scope = 'recipient') <> (p_recipient_id IS NOT NULL)
          OR p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 1 AND 2000 THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-17';
        END IF;
        IF p_scope = 'recipient' AND NOT EXISTS (SELECT 1 FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id) THEN
          RETURN 'recipient_not_found';
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['legal_hold', p_scope, p_recipient_id::text]);
        IF EXISTS (SELECT 1 FROM relay.legal_holds h
          WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.scope = p_scope
            AND h.recipient_id IS NOT DISTINCT FROM p_recipient_id AND h.state = 'active') THEN
          RETURN 'already_active';
        END IF;
        INSERT INTO relay.legal_holds (tenant_id, environment, id, scope, recipient_id, reason, state,
          placed_at, released_at)
        VALUES (v_tenant, v_env, p_id, p_scope, p_recipient_id, p_reason, 'active', now(), NULL);
        PERFORM relay_private.audit_write(v_tenant, v_env, 'legal_hold.placed', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'legal_hold', p_id::text, p_reason,
          p_record_digest);
        RETURN 'placed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.legal_hold_release(p_hold_id uuid, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
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
        SELECT h.state INTO v_state FROM relay.legal_holds h
          WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.id = p_hold_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_state = 'released' THEN
          RETURN 'already_released';
        END IF;
        UPDATE relay.legal_holds h SET state = 'released', released_at = now()
          WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.id = p_hold_id;
        PERFORM relay_private.audit_write(v_tenant, v_env, 'legal_hold.released', p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'legal_hold', p_hold_id::text, NULL,
          p_record_digest);
        RETURN 'released';
      END
      $fn$
      """
    ]
  end
end
