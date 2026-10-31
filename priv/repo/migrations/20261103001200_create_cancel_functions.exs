defmodule Relay.Repo.Migrations.CreateCancelFunctions do
  use Ecto.Migration

  @actor "text, text, text, text"

  @functions [
    {"relay_private.cancel_deliveries(uuid, text[], text)", "relay_migrator", ~w(relay_owner)},
    {"relay_private.cancel_close(uuid, text)", "relay_migrator", ~w(relay_owner)},
    {"relay_fn.cancel_event(uuid, uuid, text, integer, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.cancel_notification(uuid, uuid, text, #{@actor})", "relay_owner", ~w(relay_app)},
    {"relay_fn.cancel_by_key(uuid, text, uuid[], text[], text, integer, #{@actor})",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.cancellation_applies(uuid, uuid, text)", "relay_owner", ~w(relay_app)}
  ]

  # API-57
  # API-58
  # API-59
  # INV-60
  # C-29
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
      CREATE FUNCTION relay_private.cancel_deliveries(p_notification_id uuid, p_channels text[],
        p_rule_id text)
        RETURNS TABLE (delivery_id uuid, outcome text)
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      #variable_conflict use_column
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
        v_delivery relay.deliveries;
      BEGIN
        FOR v_delivery IN
          SELECT * FROM relay.deliveries d
          WHERE d.tenant_id = v_tenant AND d.environment = v_env
            AND d.notification_id = p_notification_id
            AND (p_channels IS NULL OR d.channel = ANY (p_channels))
          ORDER BY d.created_at, d.id
          FOR UPDATE
        LOOP
          IF v_delivery.failure_kind IS NOT NULL THEN
            CONTINUE;
          END IF;
          IF v_delivery.delivery_rank > 0 OR EXISTS (SELECT 1 FROM relay.delivery_attempts a
            WHERE a.tenant_id = v_tenant AND a.environment = v_env
              AND a.delivery_id = v_delivery.id
              AND a.state IN ('pending', 'in_flight', 'succeeded', 'unknown')) THEN
            delivery_id := v_delivery.id;
            outcome := 'already_sent';
            RETURN NEXT;
            CONTINUE;
          END IF;
          PERFORM relay_private.ledger_record(uuidv7(), v_delivery, NULL, 'relay',
            'delivery.cancelled', NULL, NULL, NULL, now(), NULL, NULL, 'cancelled', NULL,
            p_rule_id, NULL, NULL, NULL, v_delivery.traceparent);
          delivery_id := v_delivery.id;
          outcome := 'cancelled';
          RETURN NEXT;
        END LOOP;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_private.cancel_close(p_notification_id uuid, p_rule_id text)
        RETURNS boolean
      LANGUAGE plpgsql VOLATILE
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
      DECLARE
        v_tenant uuid := relay_private.ctx_tenant_id();
        v_env relay.environment := relay_private.ctx_environment();
      BEGIN
        UPDATE relay.notifications n SET state = 'cancelled', closed_at = now(),
            close_rule_id = p_rule_id, updated_at = now()
          WHERE n.tenant_id = v_tenant AND n.environment = v_env AND n.id = p_notification_id
            AND n.state = 'active'
            AND NOT EXISTS (SELECT 1 FROM relay.deliveries d
              WHERE d.tenant_id = n.tenant_id AND d.environment = n.environment
                AND d.notification_id = n.id
                AND (d.delivery_rank > 0 OR d.failure_kind IS NULL));
        RETURN FOUND;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.cancel_event(p_id uuid, p_event_id uuid, p_reason text,
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
        v_rule text := 'cancelled:' || p_id::text;
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
      """,
      ~S"""
      CREATE FUNCTION relay_fn.cancel_notification(p_id uuid, p_notification_id uuid,
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
        v_rule text := 'cancelled:' || p_id::text;
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
      """,
      ~S"""
      CREATE FUNCTION relay_fn.cancel_by_key(p_id uuid, p_cancellation_key text,
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
          v_more, p_actor_ref, now());
        RETURN QUERY SELECT 'cancelled'::text, v_cancelled, v_sent, v_missing, v_more, v_details;
      END
      $fn$
      """,
      ~S"""
      CREATE FUNCTION relay_fn.cancellation_applies(p_event_id uuid, p_recipient_id uuid,
        p_channel text)
        RETURNS uuid
      LANGUAGE sql STABLE SECURITY INVOKER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT c.id FROM relay.cancellations c
        JOIN relay.events e ON e.tenant_id = c.tenant_id AND e.environment = c.environment
          AND e.id = p_event_id
        WHERE c.tenant_id = relay_private.ctx_tenant_id()
          AND c.environment = relay_private.ctx_environment()
          AND ((c.kind = 'event' AND c.event_id = p_event_id)
            OR (c.kind = 'key' AND c.cancellation_key = e.cancellation_key
              AND e.created_at <= c.created_at
              AND (c.recipient_ids IS NULL OR p_recipient_id = ANY (c.recipient_ids))
              AND (c.channels IS NULL OR p_channel = ANY (c.channels::text[]))))
        ORDER BY c.created_at, c.id
        LIMIT 1
      $fn$
      """
    ]
  end
end
