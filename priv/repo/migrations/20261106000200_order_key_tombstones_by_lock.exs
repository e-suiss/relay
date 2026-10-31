defmodule Relay.Repo.Migrations.OrderKeyTombstonesByLock do
  use Ecto.Migration

  # API-58
  # INV-60
  # C-29
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute(event_accept())
    execute(cancel_by_key())
    execute("RESET ROLE")
  end

  defp event_accept do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.event_accept(p_id uuid, p_workflow_id uuid,
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
    """
  end

  defp cancel_by_key do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.cancel_by_key(p_id uuid, p_cancellation_key text,
      p_recipient_ids uuid[], p_channels text[], p_reason text, p_limit integer,
      p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text, p_access_record_ref text)
      RETURNS TABLE (result text, cancelled bigint, already_sent bigint, not_found bigint,
        has_more boolean, details jsonb)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_rule text := 'cancelled:' || p_id::text;
      v_notification relay.notifications;
      v_row record;
      v_cancelled bigint := 0;
      v_sent bigint := 0;
      v_seen bigint := 0;
      v_more boolean := false;
      v_matched uuid[] := ARRAY[]::uuid[];
      v_missing bigint := 0;
      v_details jsonb := '[]'::jsonb;
    BEGIN
      IF p_cancellation_key IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000
        OR p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-57';
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      PERFORM pg_advisory_xact_lock(hashtextextended('cancel:' || v_tenant::text || v_env::text
        || p_cancellation_key, 0));
      FOR v_notification IN
        SELECT n.* FROM relay.notifications n
        JOIN relay.events e ON e.tenant_id = n.tenant_id AND e.environment = n.environment
          AND e.id = n.event_id
        WHERE e.tenant_id = v_tenant AND e.environment = v_env
          AND e.cancellation_key = p_cancellation_key AND e.state = 'accepted'
          AND n.state = 'active'
          AND (p_recipient_ids IS NULL OR n.recipient_id = ANY (p_recipient_ids))
        ORDER BY n.created_at, n.id
        FOR NO KEY UPDATE OF n
      LOOP
        v_seen := v_seen + 1;
        IF v_seen > p_limit THEN
          v_more := true;
          EXIT;
        END IF;
        v_matched := v_matched || v_notification.recipient_id;
        FOR v_row IN
          SELECT * FROM relay_private.cancel_deliveries(v_notification.id, p_channels, v_rule)
        LOOP
          IF v_row.outcome = 'cancelled' THEN
            v_cancelled := v_cancelled + 1;
          ELSE
            v_sent := v_sent + 1;
          END IF;
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'notification_id', v_notification.id, 'delivery_id', v_row.delivery_id,
            'result', v_row.outcome));
        END LOOP;
        PERFORM relay_private.cancel_close(v_notification.id, v_rule);
      END LOOP;
      IF p_recipient_ids IS NOT NULL AND NOT v_more THEN
        SELECT count(*) INTO v_missing FROM unnest(p_recipient_ids) AS r(id)
          WHERE r.id IS NULL OR NOT (r.id = ANY (v_matched));
      END IF;
      INSERT INTO relay.cancellations (tenant_id, environment, id, kind, event_id,
        notification_id, cancellation_key, recipient_ids, channels, reason, cancelled_count,
        already_sent_count, not_found_count, has_more, created_by_ref, created_at)
      VALUES (v_tenant, v_env, p_id, 'key', NULL, NULL, p_cancellation_key,
        p_recipient_ids, p_channels::relay.channel[], p_reason, v_cancelled, v_sent, v_missing,
        v_more, p_actor_ref, clock_timestamp());
      RETURN QUERY SELECT 'cancelled'::text, v_cancelled, v_sent, v_missing, v_more, v_details;
    END
    $fn$
    """
  end
end
