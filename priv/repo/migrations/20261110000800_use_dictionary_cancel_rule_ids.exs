defmodule Relay.Repo.Migrations.UseDictionaryCancelRuleIds do
  use Ecto.Migration

  # DS-47 (1)
  # API-58
  # INV-60
  def up do
    execute("SET LOCAL ROLE relay_owner")
    execute(cancel_event())
    execute(cancel_notification())
    execute(cancel_by_key())
    execute(delivery_tombstone_apply())
    execute("RESET ROLE")
  end

  defp cancel_event do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.cancel_event(p_id uuid, p_event_id uuid, p_reason text,
      p_limit integer, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
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
      v_rule text := 'cancel.request:' || p_id::text;
      v_event relay.events;
      v_notification relay.notifications;
      v_row record;
      v_cancelled bigint := 0;
      v_sent bigint := 0;
      v_seen bigint := 0;
      v_more boolean := false;
      v_details jsonb := '[]'::jsonb;
    BEGIN
      IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 OR p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-57';
      END IF;
      SELECT * INTO v_event FROM relay.events e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_event_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, 0::bigint, 0::bigint, 1::bigint, false,
          '[]'::jsonb;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      FOR v_notification IN
        SELECT * FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.event_id = p_event_id
        ORDER BY n.created_at, n.id
        FOR NO KEY UPDATE
      LOOP
        v_seen := v_seen + 1;
        IF v_seen > p_limit THEN
          v_more := true;
          EXIT;
        END IF;
        IF v_notification.state <> 'active' THEN
          v_details := v_details || jsonb_build_array(jsonb_build_object(
            'notification_id', v_notification.id, 'result', 'already_closed'));
          CONTINUE;
        END IF;
        FOR v_row IN SELECT * FROM relay_private.cancel_deliveries(v_notification.id, NULL, v_rule)
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
      INSERT INTO relay.cancellations (tenant_id, environment, id, kind, event_id,
        notification_id, cancellation_key, recipient_ids, channels, reason, cancelled_count,
        already_sent_count, not_found_count, has_more, created_by_ref, created_at)
      VALUES (v_tenant, v_env, p_id, 'event', p_event_id, NULL, NULL, NULL, NULL, p_reason,
        v_cancelled, v_sent, 0, v_more, p_actor_ref, now());
      IF NOT v_more THEN
        UPDATE relay.events e SET state = 'cancelled', cancelled_at = now(),
            cancellation_id = p_id
          WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = p_event_id
            AND e.state = 'accepted';
      END IF;
      RETURN QUERY SELECT 'cancelled'::text, v_cancelled, v_sent, 0::bigint, v_more, v_details;
    END
    $fn$
    """
  end

  defp cancel_notification do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.cancel_notification(p_id uuid, p_notification_id uuid,
      p_reason text, p_actor_kind text, p_actor_ref text, p_on_behalf_of_ref text,
      p_access_record_ref text)
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
      v_rule text := 'cancel.request:' || p_id::text;
      v_notification relay.notifications;
      v_row record;
      v_cancelled bigint := 0;
      v_sent bigint := 0;
      v_details jsonb := '[]'::jsonb;
    BEGIN
      IF p_actor_ref IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'API-57';
      END IF;
      SELECT * INTO v_notification FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = p_notification_id
        FOR NO KEY UPDATE;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, 0::bigint, 0::bigint, 1::bigint, false,
          '[]'::jsonb;
        RETURN;
      END IF;
      PERFORM relay_private.assert_new_id(p_id);
      IF v_notification.state <> 'active' THEN
        v_details := jsonb_build_array(jsonb_build_object('notification_id', v_notification.id,
          'result', 'already_closed'));
      ELSE
        FOR v_row IN SELECT * FROM relay_private.cancel_deliveries(v_notification.id, NULL, v_rule)
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
      END IF;
      INSERT INTO relay.cancellations (tenant_id, environment, id, kind, event_id,
        notification_id, cancellation_key, recipient_ids, channels, reason, cancelled_count,
        already_sent_count, not_found_count, has_more, created_by_ref, created_at)
      VALUES (v_tenant, v_env, p_id, 'notification', NULL, p_notification_id, NULL, NULL, NULL,
        p_reason, v_cancelled, v_sent, 0, false, p_actor_ref, now());
      RETURN QUERY SELECT 'cancelled'::text, v_cancelled, v_sent, 0::bigint, false, v_details;
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
      v_rule text := 'cancel.request:' || p_id::text;
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

  defp delivery_tombstone_apply do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_fn.delivery_tombstone_apply(p_delivery_id uuid)
      RETURNS TABLE (result text, cancellation_id uuid)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_notification_id uuid;
      v_notification relay.notifications;
      v_delivery relay.deliveries;
      v_cancellation uuid;
      v_rule text;
    BEGIN
      SELECT d.notification_id INTO v_notification_id FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
        RETURN;
      END IF;
      SELECT * INTO v_notification FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = v_notification_id
        FOR NO KEY UPDATE;
      SELECT * INTO v_delivery FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id
        FOR UPDATE;
      IF v_delivery.failure_kind IS NOT NULL THEN
        RETURN QUERY SELECT 'terminal'::text, NULL::uuid;
        RETURN;
      END IF;
      IF v_notification.event_id IS NULL THEN
        RETURN QUERY SELECT 'none'::text, NULL::uuid;
        RETURN;
      END IF;
      v_cancellation := relay_fn.cancellation_applies(v_notification.event_id,
        v_notification.recipient_id, v_delivery.channel::text);
      IF v_cancellation IS NULL THEN
        RETURN QUERY SELECT 'none'::text, NULL::uuid;
        RETURN;
      END IF;
      IF v_delivery.delivery_rank > 0 OR EXISTS (SELECT 1 FROM relay.delivery_attempts a
        WHERE a.tenant_id = v_tenant AND a.environment = v_env AND a.delivery_id = v_delivery.id
          AND a.state IN ('pending', 'in_flight', 'succeeded', 'unknown')) THEN
        RETURN QUERY SELECT 'already_sent'::text, v_cancellation;
        RETURN;
      END IF;
      v_rule := 'cancel.request:' || v_cancellation::text;
      PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
        'delivery.cancelled', NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL,
        v_rule, NULL, NULL, NULL, v_delivery.traceparent);
      PERFORM relay_private.cancel_close(v_notification.id, v_rule);
      RETURN QUERY SELECT 'cancelled'::text, v_cancellation;
    END
    $fn$
    """
  end
end
