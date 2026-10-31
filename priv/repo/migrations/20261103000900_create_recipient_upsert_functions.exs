defmodule Relay.Repo.Migrations.CreateRecipientUpsertFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_private.recipient_address_set(uuid, relay.environment, uuid, text, uuid, bytea, bytea, uuid, uuid)",
     "relay_migrator", ~w(relay_owner)},
    {"relay_fn.recipient_upsert(uuid, text, bytea, uuid, bytea, uuid, bytea, uuid, text[], bytea, bytea, text, text, text, uuid, bytea, bytea, uuid, bytea, bytea, uuid, bigint)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.recipient_deletion_request(uuid, uuid, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.recipient_deletion_complete(uuid, uuid)", "relay_owner", ~w(relay_app)}
  ]

  # API-21
  # API-66
  # C-19
  # C-20
  # X-25
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
      CREATE FUNCTION relay_private.recipient_address_set(p_tenant_id uuid,
        p_environment relay.environment, p_recipient_id uuid, p_kind text, p_address_id uuid,
        p_address_ct bytea, p_address_bidx bytea, p_bidx_key_id uuid, p_key_id uuid)
        RETURNS boolean
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_current relay.recipient_addresses;
      BEGIN
        SELECT * INTO v_current FROM relay.recipient_addresses a
          WHERE a.tenant_id = p_tenant_id AND a.environment = p_environment
            AND a.recipient_id = p_recipient_id AND a.kind = p_kind AND a.state = 'active'
          FOR UPDATE;
        IF FOUND AND p_address_bidx IS NOT NULL AND v_current.address_bidx = p_address_bidx THEN
          RETURN false;
        END IF;
        IF NOT FOUND AND p_address_ct IS NULL THEN
          RETURN false;
        END IF;
        IF FOUND THEN
          UPDATE relay.recipient_addresses a SET state = 'replaced', state_changed_at = now(),
              updated_at = now()
            WHERE a.tenant_id = p_tenant_id AND a.environment = p_environment
              AND a.id = v_current.id;
        END IF;
        IF p_address_ct IS NOT NULL THEN
          PERFORM relay_private.assert_new_id(p_address_id);
          IF p_key_id IS NULL OR (p_address_bidx IS NULL) <> (p_bidx_key_id IS NULL) THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-19';
          END IF;
          INSERT INTO relay.recipient_addresses (tenant_id, environment, id, recipient_id, kind,
            address_ct, address_key_id, address_bidx, address_bidx_key_id, address_bidx_next, state,
            disabled_rule_id, state_changed_at, created_at, updated_at)
          VALUES (p_tenant_id, p_environment, p_address_id, p_recipient_id, p_kind, p_address_ct,
            p_key_id, p_address_bidx, p_bidx_key_id, NULL, 'active', NULL, now(), now(), now());
        END IF;
        RETURN true;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.recipient_upsert(p_id uuid, p_mode text, p_external_id_bidx bytea,
        p_bidx_key_id uuid, p_external_id_ct bytea, p_profile_dek_id uuid,
        p_profile_wrapped_dek bytea, p_wrapping_key_id uuid, p_fields text[], p_name_ct bytea,
        p_attributes_ct bytea, p_locale text, p_timezone text, p_legal_type text,
        p_email_address_id uuid, p_email_ct bytea, p_email_bidx bytea, p_phone_address_id uuid,
        p_phone_ct bytea, p_phone_bidx bytea, p_address_bidx_key_id uuid,
        p_expected_version bigint)
        RETURNS TABLE (result text, recipient_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_recipient relay.recipients;
        v_fields text[];
        v_changed boolean := false;
        v_version bigint;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        IF p_mode IS NULL
          OR p_mode NOT IN ('create', 'replace', 'patch', 'implicit', 'inbox_only', 'require')
          OR p_external_id_bidx IS NULL OR p_bidx_key_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-21';
        END IF;
        v_fields := CASE WHEN p_mode = 'replace'
          THEN ARRAY['name', 'attributes', 'locale', 'timezone', 'legal_type', 'email', 'phone']
          WHEN p_mode IN ('inbox_only', 'require') THEN ARRAY[]::text[]
          ELSE COALESCE(p_fields, ARRAY[]::text[]) END;
        PERFORM relay_private.lock_scope(ARRAY['recipient', encode(p_external_id_bidx, 'hex')]);
        SELECT * INTO v_recipient FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env
            AND (r.external_id_bidx = p_external_id_bidx
              OR r.external_id_bidx_next = p_external_id_bidx)
          FOR NO KEY UPDATE;
        IF NOT FOUND THEN
          IF p_mode IN ('require', 'patch') THEN
            RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid, NULL::bigint;
            RETURN;
          END IF;
          PERFORM relay_private.assert_new_id(p_id);
          PERFORM relay_private.assert_new_id(p_profile_dek_id);
          IF p_external_id_ct IS NULL OR p_profile_wrapped_dek IS NULL
            OR p_wrapping_key_id IS NULL THEN
            RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-20';
          END IF;
          INSERT INTO relay.recipients AS r (tenant_id, environment, id, kind, external_id_bidx,
            external_id_bidx_key_id, external_id_bidx_next, external_id_ct, external_id_key_id,
            state, deleted_at, deleted_reason, name_ct, attributes_ct, profile_key_id, locale,
            timezone, legal_type, inbox_only, version, created_at, updated_at)
          VALUES (v_tenant, v_env, p_id, 'subscriber', p_external_id_bidx, p_bidx_key_id, NULL,
            p_external_id_ct, p_profile_dek_id, 'active', NULL, NULL,
            CASE WHEN 'name' = ANY (v_fields) THEN p_name_ct END,
            CASE WHEN 'attributes' = ANY (v_fields) THEN p_attributes_ct END,
            p_profile_dek_id,
            CASE WHEN 'locale' = ANY (v_fields) THEN p_locale END,
            CASE WHEN 'timezone' = ANY (v_fields) THEN p_timezone END,
            CASE WHEN 'legal_type' = ANY (v_fields) THEN p_legal_type END,
            p_mode = 'inbox_only', 1, now(), now());
          INSERT INTO relay.subject_keys (tenant_id, environment, id, recipient_id,
            retention_class, wrapped_dek, wrapping_key_id, state, restricted_at, destroyed_at,
            destroy_reason, created_at)
          VALUES (v_tenant, v_env, p_profile_dek_id, p_id, 'recipient_profile',
            p_profile_wrapped_dek, p_wrapping_key_id, 'active', NULL, NULL, NULL, now());
          IF 'email' = ANY (v_fields) THEN
            PERFORM relay_private.recipient_address_set(v_tenant, v_env, p_id, 'email',
              p_email_address_id, p_email_ct, p_email_bidx, p_address_bidx_key_id,
              p_profile_dek_id);
          END IF;
          IF 'phone' = ANY (v_fields) THEN
            PERFORM relay_private.recipient_address_set(v_tenant, v_env, p_id, 'phone',
              p_phone_address_id, p_phone_ct, p_phone_bidx, p_address_bidx_key_id,
              p_profile_dek_id);
          END IF;
          RETURN QUERY SELECT 'created'::text, p_id, 1::bigint;
          RETURN;
        END IF;
        IF v_recipient.kind = 'agent' THEN
          RETURN QUERY SELECT 'is_agent'::text, v_recipient.id, v_recipient.version;
          RETURN;
        END IF;
        IF v_recipient.state = 'deletion_requested' THEN
          RETURN QUERY SELECT 'deletion_pending'::text, v_recipient.id, v_recipient.version;
          RETURN;
        END IF;
        IF p_mode = 'create' THEN
          RETURN QUERY SELECT 'exists'::text, v_recipient.id, v_recipient.version;
          RETURN;
        END IF;
        IF p_mode IN ('require', 'inbox_only') THEN
          RETURN QUERY SELECT 'unchanged'::text, v_recipient.id, v_recipient.version;
          RETURN;
        END IF;
        IF v_recipient.id <> p_id AND p_profile_wrapped_dek IS NOT NULL THEN
          RETURN QUERY SELECT 'exists'::text, v_recipient.id, v_recipient.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_recipient.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_recipient.id, v_recipient.version;
          RETURN;
        END IF;
        IF 'email' = ANY (v_fields) THEN
          v_changed := relay_private.recipient_address_set(v_tenant, v_env, v_recipient.id,
            'email', p_email_address_id, p_email_ct, p_email_bidx, p_address_bidx_key_id,
            v_recipient.external_id_key_id) OR v_changed;
        END IF;
        IF 'phone' = ANY (v_fields) THEN
          v_changed := relay_private.recipient_address_set(v_tenant, v_env, v_recipient.id,
            'phone', p_phone_address_id, p_phone_ct, p_phone_bidx, p_address_bidx_key_id,
            v_recipient.external_id_key_id) OR v_changed;
        END IF;
        v_changed := v_changed
          OR ('name' = ANY (v_fields) AND (p_name_ct IS NOT NULL OR v_recipient.name_ct IS NOT NULL))
          OR ('attributes' = ANY (v_fields)
            AND (p_attributes_ct IS NOT NULL OR v_recipient.attributes_ct IS NOT NULL))
          OR ('locale' = ANY (v_fields) AND p_locale IS DISTINCT FROM v_recipient.locale)
          OR ('timezone' = ANY (v_fields) AND p_timezone IS DISTINCT FROM v_recipient.timezone)
          OR ('legal_type' = ANY (v_fields)
            AND p_legal_type IS DISTINCT FROM v_recipient.legal_type)
          OR (v_recipient.inbox_only AND cardinality(v_fields) > 0);
        IF NOT v_changed THEN
          RETURN QUERY SELECT 'unchanged'::text, v_recipient.id, v_recipient.version;
          RETURN;
        END IF;
        UPDATE relay.recipients r SET
            name_ct = CASE WHEN 'name' = ANY (v_fields) THEN p_name_ct ELSE r.name_ct END,
            attributes_ct = CASE WHEN 'attributes' = ANY (v_fields) THEN p_attributes_ct
              ELSE r.attributes_ct END,
            profile_key_id = COALESCE(r.profile_key_id, r.external_id_key_id),
            locale = CASE WHEN 'locale' = ANY (v_fields) THEN p_locale ELSE r.locale END,
            timezone = CASE WHEN 'timezone' = ANY (v_fields) THEN p_timezone ELSE r.timezone END,
            legal_type = CASE WHEN 'legal_type' = ANY (v_fields) THEN p_legal_type
              ELSE r.legal_type END,
            inbox_only = r.inbox_only AND cardinality(v_fields) = 0,
            version = r.version + 1,
            updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = v_recipient.id
          RETURNING r.version INTO v_version;
        RETURN QUERY SELECT 'updated'::text, v_recipient.id, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.recipient_deletion_request(p_id uuid, p_recipient_id uuid,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, request_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_recipient relay.recipients;
        v_existing uuid;
        v_held boolean;
      BEGIN
        IF p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-66';
        END IF;
        SELECT * INTO v_recipient FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
          FOR NO KEY UPDATE;
        IF NOT FOUND OR v_recipient.state = 'deleted' OR v_recipient.kind <> 'subscriber' THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        SELECT q.id INTO v_existing FROM relay.recipient_deletion_requests q
          WHERE q.tenant_id = v_tenant AND q.environment = v_env
            AND q.recipient_id = p_recipient_id AND q.status = 'pending';
        IF FOUND THEN
          RETURN QUERY SELECT 'already_requested'::text, v_existing;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        v_held := EXISTS (SELECT 1 FROM relay.legal_holds h
          WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.state = 'active'
            AND (h.scope = 'tenant' OR h.recipient_id = p_recipient_id));
        INSERT INTO relay.recipient_deletion_requests (tenant_id, environment, id, recipient_id,
          status, erasure_id, requested_by_ref, created_at, completed_at, updated_at)
        VALUES (v_tenant, v_env, p_id, p_recipient_id,
          CASE WHEN v_held THEN 'held' ELSE 'pending' END, NULL, p_actor_ref, now(), NULL, now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'subscriber.deletion_requested',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'recipient',
          p_recipient_id::text, NULL, p_record_digest);
        IF v_held THEN
          RETURN QUERY SELECT 'held'::text, p_id;
          RETURN;
        END IF;
        UPDATE relay.recipients r SET state = 'deletion_requested', version = r.version + 1,
            updated_at = now()
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id;
        RETURN QUERY SELECT 'requested'::text, p_id;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.recipient_deletion_complete(p_request_id uuid, p_erasure_id uuid)
        RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_request relay.recipient_deletion_requests;
      BEGIN
        SELECT * INTO v_request FROM relay.recipient_deletion_requests q
          WHERE q.tenant_id = v_tenant AND q.environment = v_env AND q.id = p_request_id
          FOR UPDATE;
        IF NOT FOUND OR v_request.status <> 'pending' THEN
          RETURN 'not_pending';
        END IF;
        IF p_erasure_id IS NULL THEN
          UPDATE relay.recipient_deletion_requests q SET status = 'held', updated_at = now()
            WHERE q.tenant_id = v_tenant AND q.environment = v_env AND q.id = p_request_id;
          UPDATE relay.recipients r SET state = 'active', version = r.version + 1,
              updated_at = now()
            WHERE r.tenant_id = v_tenant AND r.environment = v_env
              AND r.id = v_request.recipient_id AND r.state = 'deletion_requested';
          RETURN 'held';
        END IF;
        UPDATE relay.recipient_deletion_requests q SET status = 'completed',
            erasure_id = p_erasure_id, completed_at = now(), updated_at = now()
          WHERE q.tenant_id = v_tenant AND q.environment = v_env AND q.id = p_request_id;
        RETURN 'completed';
      END
      $fn$
      """
    ]
  end
end
