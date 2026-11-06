defmodule Relay.Repo.Migrations.SealEventPayloadOverrides do
  use Ecto.Migration

  @old_accept "relay_fn.event_accept(uuid, uuid, uuid, uuid, uuid, text, bytea, text, text, text, text, text, text, timestamp with time zone, timestamp with time zone, boolean, text, boolean, bigint, bytea, bytea, bytea, bytea, uuid, bigint, text, text, bytea)"
  @accept "relay_fn.event_accept(uuid, uuid, uuid, uuid, uuid, text, bytea, text, text, text, text, text, text, timestamp with time zone, timestamp with time zone, boolean, text, boolean, bigint, bytea, bytea, bytea, bytea, uuid, bigint, text, text, bytea, bytea)"

  # API-23
  # API-26
  # OP-18
  # OP-25
  def up do
    execute("ALTER TABLE relay.event_payloads ADD COLUMN overrides_ct bytea")
    execute("SET LOCAL ROLE relay_owner")
    execute("DROP FUNCTION #{@old_accept}")
    execute(event_payload_erase())
    execute(subject_erase())
    execute("RESET ROLE")
    execute(event_accept())
    execute("REVOKE ALL ON FUNCTION #{@accept} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@accept} TO relay_app")
    execute("ALTER FUNCTION #{@accept} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp event_accept do
    ~S"""
    CREATE FUNCTION relay_fn.event_accept(p_id uuid, p_workflow_id uuid,
      p_workflow_version_id uuid, p_api_client_id uuid, p_subtenant_id uuid, p_source text,
      p_ce_key_digest bytea, p_dedup_key text, p_cancellation_key text, p_sender_type text,
      p_priority text, p_security_subtype text, p_on_expire text, p_send_at timestamptz,
      p_expires_at timestamptz, p_retention_none boolean, p_send_mode text, p_is_test boolean,
      p_recipient_count bigint, p_data_ct bytea, p_metadata_ct bytea, p_actor_ct bytea,
      p_ce_attributes_ct bytea, p_key_id uuid, p_plain_size bigint, p_traceparent text,
      p_interruption text, p_links_ct bytea, p_overrides_ct bytea)
      RETURNS TABLE (result text, event_id uuid, created_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_now timestamptz := clock_timestamp();
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
        cancellation_id, payload_created_at, traceparent, interruption, created_at)
      VALUES (v_tenant, v_env, p_id, p_workflow_id, p_workflow_version_id, p_api_client_id,
        v_subtenant, p_source, p_ce_key_digest, p_dedup_key, p_cancellation_key, p_sender_type,
        p_priority, p_security_subtype, p_on_expire, p_send_at, p_expires_at, p_retention_none,
        p_send_mode, p_is_test, p_recipient_count, 'accepted', NULL, NULL, v_now,
        p_traceparent, p_interruption, v_now);
      INSERT INTO relay.event_payloads (tenant_id, environment, event_id, created_at, data_ct,
        metadata_ct, actor_ct, ce_attributes_ct, links_ct, overrides_ct, key_id, plain_size,
        erased_at, erase_reason)
      VALUES (v_tenant, v_env, p_id, v_now, p_data_ct, p_metadata_ct, p_actor_ct,
        p_ce_attributes_ct, p_links_ct, p_overrides_ct, p_key_id, p_plain_size, NULL, NULL);
      RETURN QUERY SELECT 'accepted'::text, p_id, v_now;
    END
    $fn$
    """
  end

  defp event_payload_erase do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.event_payload_erase(p_event_id uuid, p_reason text)
      RETURNS text
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
      UPDATE relay.event_payloads p SET data_ct = NULL, links_ct = NULL, overrides_ct = NULL,
          erased_at = now(), erase_reason = p_reason
        WHERE p.tenant_id = v_tenant AND p.environment = v_env AND p.event_id = p_event_id
          AND p.created_at = v_created;
      RETURN 'erased';
    END
    $fn$
    """
  end

  defp subject_erase do
    """
    CREATE OR REPLACE FUNCTION relay_fn.subject_erase(p_recipient_id uuid, p_request_ref text,
      p_destroy_classes text[], p_restrict_classes text[], p_record_digest bytea,
      p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, cancelled_deliveries bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_state text;
      v_delivery relay.deliveries;
      v_count bigint := 0;
      v_destroy text[] := COALESCE(p_destroy_classes, ARRAY[]::text[]);
      v_restrict text[] := COALESCE(p_restrict_classes, ARRAY[]::text[]);
      v_waitpoint relay.waitpoints;
      v_now timestamptz := relay_private.business_now();
    BEGIN
      IF p_request_ref IS NULL OR v_destroy && v_restrict THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'OP-18';
      END IF;
      SELECT r.state INTO v_state FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, 0::bigint;
        RETURN;
      END IF;
      IF v_state = 'deleted' THEN
        RETURN QUERY SELECT 'already_erased'::text, 0::bigint;
        RETURN;
      END IF;
      IF EXISTS (SELECT 1 FROM relay.legal_holds h
        WHERE h.tenant_id = v_tenant AND h.environment = v_env AND h.state = 'active'
          AND (h.scope = 'tenant' OR h.recipient_id = p_recipient_id)) THEN
        RETURN QUERY SELECT 'held'::text, 0::bigint;
        RETURN;
      END IF;
      UPDATE relay.subject_keys k SET wrapped_dek = NULL, state = 'destroyed',
          destroyed_at = now(), destroy_reason = 'erasure'
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.recipient_id = p_recipient_id
          AND k.retention_class = ANY (v_destroy) AND k.state <> 'destroyed';
      UPDATE relay.subject_keys k SET state = 'restricted', restricted_at = now()
        WHERE k.tenant_id = v_tenant AND k.environment = v_env AND k.recipient_id = p_recipient_id
          AND k.retention_class = ANY (v_restrict) AND k.state = 'active';
      UPDATE relay.recipients r SET state = 'deleted', deleted_at = now(),
          deleted_reason = 'erasure', external_id_bidx = NULL, external_id_bidx_key_id = NULL,
          external_id_bidx_next = NULL, version = r.version + 1, updated_at = now()
        WHERE r.tenant_id = v_tenant AND r.environment = v_env AND r.id = p_recipient_id;
      UPDATE relay.recipient_addresses a SET state = 'deleted', address_bidx = NULL,
          address_bidx_key_id = NULL, address_bidx_next = NULL, disabled_rule_id = NULL,
          state_changed_at = now(), updated_at = now()
        WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.recipient_id = p_recipient_id
          AND a.state <> 'deleted';
      UPDATE relay.event_payloads p SET data_ct = NULL, metadata_ct = NULL, actor_ct = NULL,
          links_ct = NULL, overrides_ct = NULL, erased_at = COALESCE(p.erased_at, now()),
          erase_reason = COALESCE(p.erase_reason, 'subject_erasure')
        FROM relay.events e
        WHERE p.tenant_id = v_tenant AND p.environment = v_env
          AND e.tenant_id = p.tenant_id AND e.environment = p.environment AND e.id = p.event_id
          AND p.created_at = e.payload_created_at
          AND EXISTS (SELECT 1 FROM relay.notifications n
            WHERE n.tenant_id = e.tenant_id AND n.environment = e.environment
              AND n.event_id = e.id AND n.recipient_id = p_recipient_id);
      FOR v_delivery IN
        SELECT * FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.recipient_id = p_recipient_id
          AND d.delivery_rank = 0 AND d.failure_kind IS NULL
        ORDER BY d.created_at, d.id
        FOR NO KEY UPDATE
      LOOP
        PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
          'delivery.cancelled', NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL,
          'subject_erasure', NULL, NULL, NULL, v_delivery.traceparent);
        v_count := v_count + 1;
      END LOOP;
      FOR v_waitpoint IN
        SELECT * FROM relay.waitpoints w
        WHERE w.tenant_id = v_tenant AND w.environment = v_env
          AND ((w.waiter_kind = 'agent' AND w.waiter_ref = p_recipient_id)
            OR EXISTS (SELECT 1 FROM relay.waitpoint_responders s
              WHERE s.tenant_id = w.tenant_id AND s.environment = w.environment
                AND s.waitpoint_id = w.id AND s.recipient_id = p_recipient_id))
        ORDER BY w.id
        FOR NO KEY UPDATE
      LOOP
        UPDATE relay.waitpoints w SET content_ct = NULL, claim_text_ct = NULL,
            default_response_ct = NULL, field_key_id = NULL,
            fields_erased_at = COALESCE(w.fields_erased_at, now()),
            state = CASE WHEN w.state IN ('open', 'stalled') THEN 'cancelled' ELSE w.state END,
            cancelled_at = CASE WHEN w.state IN ('open', 'stalled') THEN v_now ELSE w.cancelled_at END,
            cancel_reason = CASE WHEN w.state IN ('open', 'stalled') THEN 'subject_erasure'
              ELSE w.cancel_reason END,
            stalled_at = CASE WHEN w.state IN ('open', 'stalled') THEN NULL ELSE w.stalled_at END,
            state_changed_at = CASE WHEN w.state IN ('open', 'stalled') THEN v_now
              ELSE w.state_changed_at END,
            version = CASE WHEN w.state IN ('open', 'stalled') THEN w.version + 1 ELSE w.version END,
            updated_at = now()
          WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_waitpoint.id;
        IF v_waitpoint.state IN ('open', 'stalled') THEN
          SELECT * INTO v_waitpoint FROM relay.waitpoints w
            WHERE w.tenant_id = v_tenant AND w.environment = v_env AND w.id = v_waitpoint.id;
          PERFORM relay_private.waitpoint_release(v_waitpoint);
          PERFORM relay_private.waitpoint_emit(v_waitpoint, 'waitpoint.cancelled', NULL, NULL, NULL,
            NULL);
        END IF;
      END LOOP;
      UPDATE relay.mailboxes m SET state = 'deleted', deleted_at = now(), deleted_reason = 'erasure',
          updated_at = now()
        WHERE m.tenant_id = v_tenant AND m.environment = v_env
          AND m.owner_kind IN ('subscriber', 'agent') AND m.owner_ref = p_recipient_id
          AND m.state <> 'deleted';
      INSERT INTO relay.erasure_log (tenant_id, environment, id, recipient_id, request_ref,
        destroyed_classes, restricted_classes, cancelled_deliveries, backup_copies_expire_at,
        created_at)
      VALUES (v_tenant, v_env, uuidv7(), p_recipient_id, p_request_ref, v_destroy, v_restrict,
        v_count, now() + interval '35 days', now());
      PERFORM relay_private.audit_write(v_tenant, v_env, 'subject.erased', p_actor_kind,
        p_actor_ref, p_on_behalf_of_ref, p_access_record_ref, 'recipient', p_recipient_id::text,
        NULL, p_record_digest);
      RETURN QUERY SELECT 'erased'::text, v_count;
    END
    $fn$
    """
  end
end
