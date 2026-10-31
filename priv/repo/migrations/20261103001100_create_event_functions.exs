defmodule Relay.Repo.Migrations.CreateEventFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"
  @old_accept "relay_fn.notification_accept(uuid, uuid, uuid, text, text, text, text, text, text, timestamp with time zone, boolean, text)"

  @functions [
    {"relay_fn.event_accept(uuid, uuid, uuid, uuid, uuid, text, bytea, text, text, text, text, text, text, timestamp with time zone, timestamp with time zone, boolean, text, boolean, bigint, bytea, bytea, bytea, bytea, uuid, bigint, text)",
     ~w(relay_app)},
    {"relay_fn.event_payload_erase(uuid, text)", ~w(relay_app)},
    {"relay_fn.notification_accept(uuid, uuid, uuid, text, text, text, text, text, text, timestamp with time zone, boolean, text, uuid, uuid, uuid)",
     ~w(relay_app)},
    {"relay_fn.event_type_mapping_create(uuid, text, text, text, text, text, text[], bytea, #{@actor})",
     ~w(relay_app)},
    {"relay_fn.event_type_mapping_replace(uuid, text, text, text, text, text, text[], bigint, bytea, #{@actor})",
     ~w(relay_app)},
    {"relay_fn.event_type_mapping_archive(uuid, bigint, bytea, #{@actor})", ~w(relay_app)},
    {"relay_fn.event_type_mapping_resolve(text, text)", ~w(relay_app relay_report)}
  ]

  # C-28
  # C-29
  # API-16
  # API-19
  # API-20
  # API-25
  # API-26
  # API-28
  # API-29
  # MD-16
  # OP-7
  # OP-8
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute("DROP FUNCTION #{@old_accept}")
    execute("RESET ROLE")
    Enum.each(statements(), &execute/1)

    for {signature, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      execute("ALTER FUNCTION #{signature} OWNER TO relay_owner")
    end
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_fn.event_accept(p_id uuid, p_workflow_id uuid,
        p_workflow_version_id uuid, p_api_client_id uuid, p_subtenant_id uuid, p_source text,
        p_ce_key_digest bytea, p_dedup_key text, p_cancellation_key text, p_sender_type text,
        p_priority text, p_security_subtype text, p_on_expire text, p_send_at timestamptz,
        p_expires_at timestamptz, p_retention_none boolean, p_send_mode text, p_is_test boolean,
        p_recipient_count bigint, p_data_ct bytea, p_metadata_ct bytea, p_actor_ct bytea,
        p_ce_attributes_ct bytea, p_key_id uuid, p_plain_size bigint, p_traceparent text)
        RETURNS TABLE (result text, event_id uuid, created_at timestamptz)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_now timestamptz := now();
        v_published uuid;
        v_subtenant uuid;
        v_state text;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::timestamptz;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        IF p_workflow_id IS NULL OR p_workflow_version_id IS NULL OR p_source IS NULL
          OR p_sender_type IS NULL OR p_priority IS NULL OR p_retention_none IS NULL
          OR p_is_test IS NULL OR p_recipient_count IS NULL OR p_key_id IS NULL
          OR p_plain_size IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-20';
        END IF;
        SELECT w.published_version_id INTO v_published FROM relay.workflows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = p_workflow_id
            AND w.state = 'active';
        IF v_published IS NULL THEN
          RETURN QUERY SELECT 'workflow_not_published'::text, NULL::uuid, NULL::timestamptz;
          RETURN;
        END IF;
        IF v_published <> p_workflow_version_id THEN
          RETURN QUERY SELECT 'version_not_current'::text, NULL::uuid, NULL::timestamptz;
          RETURN;
        END IF;
        IF p_send_mode IS NOT NULL AND v_env <> 'test' THEN
          RETURN QUERY SELECT 'send_mode_not_allowed'::text, NULL::uuid, NULL::timestamptz;
          RETURN;
        END IF;
        IF p_send_at IS NOT NULL
          AND (p_send_at <= v_now OR p_send_at > v_now + interval '90 days') THEN
          RETURN QUERY SELECT 'send_at_invalid'::text, NULL::uuid, NULL::timestamptz;
          RETURN;
        END IF;
        IF p_subtenant_id IS NOT NULL THEN
          SELECT s.state INTO v_state FROM relay.subtenants s
            WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id;
          IF v_state = 'suspended' THEN
            RETURN QUERY SELECT 'subtenant_suspended'::text, NULL::uuid, NULL::timestamptz;
            RETURN;
          END IF;
          IF v_state = 'active' THEN
            v_subtenant := p_subtenant_id;
          END IF;
        END IF;
        INSERT INTO relay.events (tenant_id, environment, id, workflow_id, workflow_version_id,
          api_client_id, subtenant_id, source, ce_key_digest, dedup_key, cancellation_key,
          sender_type, priority, security_subtype, on_expire, send_at, expires_at,
          retention_none, send_mode, is_test, recipient_count, state, cancelled_at,
          cancellation_id, payload_created_at, traceparent, created_at)
        VALUES (v_tenant, v_env, p_id, p_workflow_id, p_workflow_version_id, p_api_client_id,
          v_subtenant, p_source, p_ce_key_digest, p_dedup_key, p_cancellation_key, p_sender_type,
          p_priority, p_security_subtype, p_on_expire, p_send_at, p_expires_at, p_retention_none,
          p_send_mode, p_is_test, p_recipient_count, 'accepted', NULL, NULL, v_now,
          p_traceparent, v_now);
        INSERT INTO relay.event_payloads (tenant_id, environment, event_id, created_at, data_ct,
          metadata_ct, actor_ct, ce_attributes_ct, key_id, plain_size, erased_at, erase_reason)
        VALUES (v_tenant, v_env, p_id, v_now, p_data_ct, p_metadata_ct, p_actor_ct,
          p_ce_attributes_ct, p_key_id, p_plain_size, NULL, NULL);
        RETURN QUERY SELECT 'accepted'::text, p_id, v_now;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.event_payload_erase(p_event_id uuid, p_reason text) RETURNS text
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_created timestamptz;
        v_erased timestamptz;
      BEGIN
        IF p_reason IS NULL OR p_reason NOT IN ('security_subtype', 'retention_none') THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-26';
        END IF;
        SELECT e.payload_created_at INTO v_created FROM relay.events e
          WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_event_id;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-26';
        END IF;
        SELECT p.erased_at INTO v_erased FROM relay.event_payloads p
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.event_id = p_event_id
            AND p.created_at = v_created
          FOR UPDATE;
        IF v_erased IS NOT NULL THEN
          RETURN 'already_erased';
        END IF;
        IF EXISTS (SELECT 1 FROM relay.notifications n
          JOIN relay.deliveries d ON d.tenant_id = n.tenant_id AND d.environment = n.environment
            AND d.notification_id = n.id
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.event_id = p_event_id
            AND d.delivery_rank = 0 AND d.failure_kind IS NULL) THEN
          RETURN 'not_terminal';
        END IF;
        UPDATE relay.event_payloads p SET data_ct = NULL, erased_at = now(),
            erase_reason = p_reason
          WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.event_id = p_event_id
            AND p.created_at = v_created;
        RETURN 'erased';
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.notification_accept(p_id uuid, p_recipient_id uuid,
        p_subtenant_id uuid, p_dedup_key text, p_message_class text, p_security_subtype text,
        p_sender_type text, p_subject_type text, p_subject_id text, p_expires_at timestamptz,
        p_is_test boolean, p_traceparent text, p_event_id uuid DEFAULT NULL,
        p_workflow_id uuid DEFAULT NULL, p_workflow_version_id uuid DEFAULT NULL)
        RETURNS TABLE (result text, notification_id uuid, original_event_id uuid)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_id uuid;
        v_event uuid;
      BEGIN
        IF relay_private.tenant_status() <> 'active' THEN
          RETURN QUERY SELECT 'tenant_inactive'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        IF p_dedup_key IS NULL OR char_length(p_dedup_key) NOT BETWEEN 1 AND 512
          OR p_message_class IS NULL OR p_sender_type IS NULL OR p_is_test IS NULL
          OR (p_event_id IS NULL) <> (p_workflow_id IS NULL)
          OR (p_workflow_id IS NULL) <> (p_workflow_version_id IS NULL) THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'C-29';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM relay.recipients r
          WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
            AND r.state = 'active') THEN
          RETURN QUERY SELECT 'recipient_not_found'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        IF p_subtenant_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM relay.subtenants s
          WHERE s.tenant_id = v_tenant AND s.environment = v_env AND s.id = p_subtenant_id
            AND s.state = 'active') THEN
          RETURN QUERY SELECT 'subtenant_not_found'::text, NULL::uuid, NULL::uuid;
          RETURN;
        END IF;
        INSERT INTO relay.notifications AS n (tenant_id, environment, id, recipient_id,
          subtenant_id, dedup_key, message_class, security_subtype, sender_type, subject_type,
          subject_id, expires_at, is_test, state, closed_at, close_rule_id, duplicate_count,
          last_duplicate_at, traceparent, event_id, workflow_id, workflow_version_id, created_at,
          updated_at)
        VALUES (v_tenant, v_env, p_id, p_recipient_id, p_subtenant_id, p_dedup_key,
          p_message_class, p_security_subtype, p_sender_type, p_subject_type, p_subject_id,
          p_expires_at, p_is_test, 'active', NULL, NULL, 0, NULL, p_traceparent, p_event_id,
          p_workflow_id, p_workflow_version_id, now(), now())
        ON CONFLICT (tenant_id, environment, dedup_key, recipient_id) DO NOTHING
        RETURNING n.id INTO v_id;
        IF v_id IS NOT NULL THEN
          RETURN QUERY SELECT 'created'::text, v_id, p_event_id;
          RETURN;
        END IF;
        UPDATE relay.notifications n SET duplicate_count = n.duplicate_count + 1,
            last_duplicate_at = now(), updated_at = now()
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.dedup_key = p_dedup_key
            AND n.recipient_id = p_recipient_id
          RETURNING n.id, n.event_id INTO v_id, v_event;
        RETURN QUERY SELECT 'duplicate'::text, v_id, v_event;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.event_type_mapping_create(p_id uuid, p_type text, p_source text,
        p_workflow_key text, p_to_pointer text, p_tenant_pointer text, p_data_fields text[],
        p_record_digest bytea, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
        p_access_record_ref text)
        RETURNS TABLE (result text, mapping_id uuid, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_workflow uuid;
        v_existing uuid;
      BEGIN
        IF p_type IS NULL OR p_to_pointer IS NULL OR p_data_fields IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'MD-16';
        END IF;
        SELECT w.id INTO v_workflow FROM relay.workflows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.key = p_workflow_key
            AND w.state = 'active';
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'workflow_not_found'::text, NULL::uuid, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.lock_scope(ARRAY['event_type_mapping', p_type]);
        SELECT m.id INTO v_existing FROM relay.event_type_mappings m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.type = p_type
            AND m.source IS NOT DISTINCT FROM p_source AND m.state = 'active';
        IF FOUND THEN
          RETURN QUERY SELECT 'conflict'::text, v_existing, NULL::bigint;
          RETURN;
        END IF;
        PERFORM relay_private.assert_new_id(p_id);
        INSERT INTO relay.event_type_mappings (tenant_id, environment, id, type, source,
          workflow_id, to_pointer, tenant_pointer, data_fields, state, version, created_at,
          updated_at)
        VALUES (v_tenant, v_env, p_id, p_type, p_source, v_workflow, p_to_pointer,
          p_tenant_pointer, p_data_fields, 'active', 1, now(), now());
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'event_type_mapping.changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'event_type_mapping', p_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'created'::text, p_id, 1::bigint;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.event_type_mapping_replace(p_mapping_id uuid, p_type text,
        p_source text, p_workflow_key text, p_to_pointer text, p_tenant_pointer text,
        p_data_fields text[], p_expected_version bigint, p_record_digest bytea,
        p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
        RETURNS TABLE (result text, version bigint)
      LANGUAGE plpgsql VOLATILE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_mapping relay.event_type_mappings;
        v_workflow uuid;
        v_version bigint;
      BEGIN
        IF p_type IS NULL OR p_to_pointer IS NULL OR p_data_fields IS NULL THEN
          RAISE EXCEPTION 'invalid_argument' USING HINT = 'MD-16';
        END IF;
        SELECT * INTO v_mapping FROM relay.event_type_mappings m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mapping_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_mapping.state = 'archived' THEN
          RETURN QUERY SELECT 'archived'::text, v_mapping.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_mapping.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_mapping.version;
          RETURN;
        END IF;
        SELECT w.id INTO v_workflow FROM relay.workflows w
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.key = p_workflow_key
            AND w.state = 'active';
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'workflow_not_found'::text, v_mapping.version;
          RETURN;
        END IF;
        IF v_mapping.type = p_type AND v_mapping.source IS NOT DISTINCT FROM p_source
          AND v_mapping.workflow_id = v_workflow AND v_mapping.to_pointer = p_to_pointer
          AND v_mapping.tenant_pointer IS NOT DISTINCT FROM p_tenant_pointer
          AND v_mapping.data_fields = p_data_fields THEN
          RETURN QUERY SELECT 'unchanged'::text, v_mapping.version;
          RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM relay.event_type_mappings m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.type = p_type
            AND m.source IS NOT DISTINCT FROM p_source AND m.state = 'active'
            AND m.id <> p_mapping_id) THEN
          RETURN QUERY SELECT 'conflict'::text, v_mapping.version;
          RETURN;
        END IF;
        UPDATE relay.event_type_mappings m SET type = p_type, source = p_source,
            workflow_id = v_workflow, to_pointer = p_to_pointer, tenant_pointer = p_tenant_pointer,
            data_fields = p_data_fields, version = m.version + 1, updated_at = now()
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mapping_id
          RETURNING m.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'event_type_mapping.changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'event_type_mapping', p_mapping_id::text, NULL, p_record_digest);
        RETURN QUERY SELECT 'replaced'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.event_type_mapping_archive(p_mapping_id uuid,
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
        v_mapping relay.event_type_mappings;
        v_version bigint;
      BEGIN
        SELECT * INTO v_mapping FROM relay.event_type_mappings m
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mapping_id
          FOR UPDATE;
        IF NOT FOUND THEN
          RETURN QUERY SELECT 'not_found'::text, NULL::bigint;
          RETURN;
        END IF;
        IF v_mapping.state = 'archived' THEN
          RETURN QUERY SELECT 'already_archived'::text, v_mapping.version;
          RETURN;
        END IF;
        IF p_expected_version IS NOT NULL AND p_expected_version <> v_mapping.version THEN
          RETURN QUERY SELECT 'version_conflict'::text, v_mapping.version;
          RETURN;
        END IF;
        UPDATE relay.event_type_mappings m SET state = 'archived', version = m.version + 1,
            updated_at = now()
          WHERE m.tenant_id = v_tenant AND m.environment = v_env AND m.id = p_mapping_id
          RETURNING m.version INTO v_version;
        PERFORM relay_private.audit_write(v_tenant, v_env::text, 'event_type_mapping.changed',
          p_actor_kind, p_actor_ref, p_on_behalf_of_ref, p_access_record_ref,
          'event_type_mapping', p_mapping_id::text, 'archived', p_record_digest);
        RETURN QUERY SELECT 'archived'::text, v_version;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.event_type_mapping_resolve(p_type text, p_source text)
        RETURNS TABLE (mapping_id uuid, workflow_id uuid, to_pointer text, tenant_pointer text,
          data_fields text[])
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT m.id, m.workflow_id, m.to_pointer, m.tenant_pointer, m.data_fields
        FROM relay.event_type_mappings m
        WHERE m.tenant_id = relay_private.ctx_tenant_id()
          AND m.environment = relay_private.ctx_environment()
          AND m.type = p_type AND m.state = 'active'
          AND (m.source = p_source OR m.source IS NULL)
        ORDER BY (m.source IS NULL), m.id
        LIMIT 1
      $fn$
      """
    ]
  end
end
