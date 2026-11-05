defmodule Relay.Repo.Migrations.CreateProviderFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_fn.provider_account_put(uuid, text, text, text, uuid, text, bigint, bigint, boolean, text[], text, date, jsonb, bigint, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.provider_account_verify(uuid, text, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.provider_account_rotate_credential(uuid, uuid, text, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.provider_account_set_health(uuid, text)", "relay_owner", ~w(relay_app)},
    {"relay_fn.sender_identity_put(uuid, uuid, uuid, text, text, text, text, text, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.sender_identity_suspend(uuid, boolean, text, bytea, #{@actor})", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.channel_identity_put(uuid, text, text, text, uuid, bytea, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.recipient_address_disable(uuid, text, text, text)", "relay_owner", ~w(relay_app)}
  ]

  # C-25
  # C-26
  # C-45
  # CH-11
  # CH-14
  # INV-14
  # INV-43
  # TN-10
  # TN-21
  # TN-26
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
      CREATE FUNCTION relay_fn.provider_account_put(p_id uuid, p_channel text, p_provider text,
        p_ownership text, p_credential_ref_id uuid, p_role text, p_priority bigint,
        p_weight bigint, p_in_installation boolean, p_processing_countries text[],
        p_transfer_basis text, p_scc_notified_on date, p_settings jsonb,
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
        v_row relay.provider_accounts;
        v_reset boolean;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::bigint;
          RETURN;
        END IF;
        IF p_channel IS NULL OR p_provider IS NULL OR p_ownership IS NULL OR p_role IS NULL
          OR p_priority IS NULL OR p_weight IS NULL OR p_in_installation IS NULL
          OR p_processing_countries IS NULL OR p_transfer_basis IS NULL OR p_settings IS NULL
          OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-45';
        END IF;
        IF p_credential_ref_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.secret_refs s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_credential_ref_id
            AND s.kind = 'provider_credential' AND s.state = 'active') THEN
          RETURN QUERY SELECT 'credential_not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT * INTO v_row FROM relay.provider_accounts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          IF p_expected_version IS NOT NULL THEN
            RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
            RETURN;
          END IF;
          PERFORM relay_private.assert_new_id(p_id);
          INSERT INTO relay.provider_accounts (tenant_id, environment, id, channel, provider,
            ownership, credential_ref_id, role, priority, weight, state, verification_state,
            verified_at, verification_rule_id, in_installation, processing_countries,
            transfer_basis, scc_notified_on, health, health_checked_at, settings, version,
            created_at, updated_at)
          VALUES (v_tenant, v_env, p_id, p_channel::relay.channel, p_provider, p_ownership,
            p_credential_ref_id, p_role, p_priority, p_weight, 'active', 'unverified', NULL, NULL,
            p_in_installation, p_processing_countries, p_transfer_basis, p_scc_notified_on,
            'unknown', NULL, p_settings, 1, now(), now());
          PERFORM relay_private.audit_write(v_tenant, v_env::text, 'provider_account.changed',
            p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
            'provider_account', p_id::text, 'created', p_record_digest);
          RETURN QUERY SELECT 'created'::text, 1::bigint;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_row.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_row.version;
          RETURN;
        END IF;
        IF (v_row.channel::text, v_row.provider, v_row.ownership, v_row.credential_ref_id,
            v_row.role, v_row.priority, v_row.weight, v_row.in_installation,
            v_row.processing_countries, v_row.transfer_basis, v_row.scc_notified_on,
            v_row.settings)
          IS NOT DISTINCT FROM (p_channel, p_provider, p_ownership, p_credential_ref_id, p_role,
            p_priority, p_weight, p_in_installation, p_processing_countries, p_transfer_basis,
            p_scc_notified_on, p_settings) THEN
          RETURN QUERY SELECT 'unchanged'::text, v_row.version;
          RETURN;
        END IF;
        v_reset := (v_row.channel::text, v_row.provider, v_row.ownership, v_row.credential_ref_id,
            v_row.settings)
          IS DISTINCT FROM (p_channel, p_provider, p_ownership, p_credential_ref_id, p_settings);
        UPDATE relay.provider_accounts a SET channel = p_channel::relay.channel,
            provider = p_provider, ownership = p_ownership, credential_ref_id = p_credential_ref_id,
            role = p_role, priority = p_priority, weight = p_weight,
            verification_state = CASE WHEN v_reset THEN 'unverified' ELSE a.verification_state END,
            verified_at = CASE WHEN v_reset THEN NULL ELSE a.verified_at END,
            verification_rule_id = CASE WHEN v_reset THEN NULL ELSE a.verification_rule_id END,
            in_installation = p_in_installation, processing_countries = p_processing_countries,
            transfer_basis = p_transfer_basis, scc_notified_on = p_scc_notified_on,
            settings = p_settings, version = a.version + 1, updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'provider_account.changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'provider_account', p_id::text, 'updated', p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_row.version + 1;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.provider_account_verify(p_id uuid, p_state text, p_rule_id text,
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.provider_accounts;
      BEGIN
        IF p_state IS NULL OR p_state NOT IN ('unverified', 'pending', 'verified', 'failed')
          OR p_actor_ref IS NULL OR (p_state = 'failed' AND p_rule_id IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-14';
        END IF;
        SELECT * INTO v_row FROM relay.provider_accounts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.verification_state = p_state
          AND v_row.verification_rule_id IS NOT DISTINCT FROM p_rule_id THEN
          RETURN 'unchanged';
        END IF;
        UPDATE relay.provider_accounts a SET verification_state = p_state,
            verified_at = CASE WHEN p_state = 'verified' THEN now() END,
            verification_rule_id = p_rule_id, version = a.version + 1, updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'provider_account.verified',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'provider_account', p_id::text, p_state, p_record_digest);
        RETURN 'changed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.provider_account_rotate_credential(p_id uuid,
        p_credential_ref_id uuid, p_step_up_ref text, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.provider_accounts;
      BEGIN
        IF p_credential_ref_id IS NULL OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-26';
        END IF;
        IF p_step_up_ref IS NULL THEN
          RETURN 'step_up_required';
        END IF;
        SELECT * INTO v_row FROM relay.provider_accounts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF v_row.ownership <> 'tenant' THEN
          RETURN 'not_tenant_owned';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM relay.secret_refs s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_credential_ref_id
            AND s.kind = 'provider_credential' AND s.state = 'active') THEN
          RETURN 'credential_not_found';
        END IF;
        UPDATE relay.provider_accounts a SET credential_ref_id = p_credential_ref_id,
            version = a.version + 1, updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text,
          'provider_account.credential_rotated', p_actor_kind, p_actor_ref, p_on_behalf_of_ref,
          p_access_record_ref, 'provider_account', p_id::text, p_step_up_ref, p_record_digest);
        RETURN 'rotated';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.provider_account_set_health(p_id uuid, p_health text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_health text;
      BEGIN
        IF p_health IS NULL OR p_health NOT IN ('unknown', 'healthy', 'degraded', 'down') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-45';
        END IF;
        SELECT a.health INTO v_health FROM relay.provider_accounts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        UPDATE relay.provider_accounts a SET health = p_health, health_checked_at = now(),
            updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.id = p_id;
        IF v_health = p_health THEN
          RETURN 'unchanged';
        END IF;
        RETURN 'updated';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.sender_identity_put(p_id uuid, p_provider_account_id uuid,
        p_subtenant_id uuid, p_channel text, p_kind text, p_value text, p_country text,
        p_approval_state text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
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
        v_row relay.sender_identities;
      BEGIN
        IF p_channel IS NULL OR p_kind IS NULL OR p_value IS NULL OR p_approval_state IS NULL
          OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-25';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM relay.provider_accounts a
          WHERE a.tenant_id = v_tenant AND a.environment = v_env
            AND a.id = p_provider_account_id) THEN
          RETURN QUERY SELECT 'account_not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF p_subtenant_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id) THEN
          RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT * INTO v_row FROM relay.sender_identities i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          PERFORM relay_private.assert_new_id(p_id);
          INSERT INTO relay.sender_identities (tenant_id, environment, id, provider_account_id,
            subtenant_id, channel, kind, value, country, approval_state, suspended_at,
            suspension_rule_id, version, created_at, updated_at)
          VALUES (v_tenant, v_env, p_id, p_provider_account_id, p_subtenant_id,
            p_channel::relay.channel, p_kind, p_value, p_country, p_approval_state, NULL, NULL, 1,
            now(), now());
          PERFORM relay_private.audit_write(v_tenant, v_env::text, 'sender_identity.changed',
            p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
            'sender_identity', p_id::text, 'created', p_record_digest);
          RETURN QUERY SELECT 'created'::text, 1::bigint;
          RETURN;
        END IF;
        IF (v_row.provider_account_id, v_row.subtenant_id, v_row.channel::text, v_row.kind,
            v_row.value, v_row.country, v_row.approval_state)
          IS NOT DISTINCT FROM (p_provider_account_id, p_subtenant_id, p_channel, p_kind, p_value,
            p_country, p_approval_state) THEN
          RETURN QUERY SELECT 'unchanged'::text, v_row.version;
          RETURN;
        END IF;
        UPDATE relay.sender_identities i SET provider_account_id = p_provider_account_id,
            subtenant_id = p_subtenant_id, channel = p_channel::relay.channel, kind = p_kind,
            value = p_value, country = p_country, approval_state = p_approval_state,
            version = i.version + 1, updated_at = now()
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'sender_identity.changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'sender_identity', p_id::text, 'updated', p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_row.version + 1;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.sender_identity_suspend(p_id uuid, p_suspended boolean,
        p_rule_id text, p_record_digest bytea, p_actor_kind text, p_actor_ref text,
        p_on_behalf_of_ref text, p_access_record_ref text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.sender_identities;
        v_action text;
      BEGIN
        IF p_suspended IS NULL OR p_actor_ref IS NULL OR (p_suspended AND p_rule_id IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'TN-10';
        END IF;
        SELECT * INTO v_row FROM relay.sender_identities i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN 'not_found';
        END IF;
        IF (v_row.suspended_at IS NOT NULL) = p_suspended THEN
          RETURN 'unchanged';
        END IF;
        v_action := CASE WHEN p_suspended THEN 'sender_identity.suspended'
          ELSE 'sender_identity.resumed' END;
        UPDATE relay.sender_identities i
          SET suspended_at = CASE WHEN p_suspended THEN now() END,
            suspension_rule_id = CASE WHEN p_suspended THEN p_rule_id END,
            version = i.version + 1, updated_at = now()
          WHERE i.tenant_id = v_tenant AND i.environment = v_env AND i.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, v_action, p_actor_kind,
          p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'sender_identity', p_id::text,
          p_rule_id, p_record_digest);
        IF p_suspended THEN
          RETURN 'suspended';
        END IF;
        RETURN 'resumed';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.channel_identity_put(p_id uuid, p_channel text, p_kind text,
        p_app_ref text, p_secret_ref_id uuid, p_record_digest bytea, p_actor_kind text,
        p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_row relay.channel_identities;
      BEGIN
        IF p_channel IS NULL OR p_kind IS NULL OR p_app_ref IS NULL OR p_secret_ref_id IS NULL
          OR p_actor_ref IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-26';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM relay.secret_refs s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_secret_ref_id
            AND s.kind = 'channel_identity' AND s.state = 'active') THEN
          RETURN QUERY SELECT 'secret_not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        SELECT * INTO v_row FROM relay.channel_identities c
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id
          FOR UPDATE;
        IF NOT FOUND THEN
          PERFORM relay_private.assert_new_id(p_id);
          INSERT INTO relay.channel_identities (tenant_id, environment, id, channel, kind,
            app_ref, secret_ref_id, state, version, created_at, updated_at)
          VALUES (v_tenant, v_env, p_id, p_channel::relay.channel, p_kind, p_app_ref,
            p_secret_ref_id, 'active', 1, now(), now());
          PERFORM relay_private.audit_write(v_tenant, v_env::text, 'channel_identity.changed',
            p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
            'channel_identity', p_id::text, 'created', p_record_digest);
          RETURN QUERY SELECT 'created'::text, 1::bigint;
          RETURN;
        END IF;
        IF (v_row.channel::text, v_row.kind, v_row.app_ref, v_row.secret_ref_id)
          IS NOT DISTINCT FROM (p_channel, p_kind, p_app_ref, p_secret_ref_id) THEN
          RETURN QUERY SELECT 'unchanged'::text, v_row.version;
          RETURN;
        END IF;
        UPDATE relay.channel_identities c SET channel = p_channel::relay.channel, kind = p_kind,
            app_ref = p_app_ref, secret_ref_id = p_secret_ref_id, version = c.version + 1,
            updated_at = now()
          WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.id = p_id;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'channel_identity.changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'channel_identity', p_id::text, 'updated', p_record_digest);
        RETURN QUERY SELECT 'updated'::text, v_row.version + 1;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.recipient_address_disable(p_recipient_id uuid, p_kind text,
        p_channel text, p_rule_id text)
        RETURNS TABLE (result text, address_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_id uuid;
      BEGIN
        IF p_kind IS NULL OR p_kind NOT IN ('email', 'phone') OR p_channel IS NULL
          OR p_rule_id IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'CH-11';
        END IF;
        UPDATE relay.recipient_addresses a SET state = 'disabled', disabled_rule_id = p_rule_id,
            state_changed_at = now(), updated_at = now()
          WHERE a.tenant_id = v_tenant AND a.environment = v_env
            AND a.recipient_id = p_recipient_id AND a.kind = p_kind AND a.state = 'active'
          RETURNING a.id INTO v_id;
        IF v_id IS NULL THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_fn.outbox_append(uuidv7(), 'address.disabled',
          'recipient:' || p_recipient_id::text,
          jsonb_build_object('address_id', v_id, 'recipient_id', p_recipient_id,
            'channel', p_channel, 'rule_id', p_rule_id),
          NULL);
        RETURN QUERY SELECT 'disabled'::text, v_id;
      END
      $fn$
      """
    ]
  end
end
