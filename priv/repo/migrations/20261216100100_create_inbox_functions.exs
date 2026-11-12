defmodule Relay.Repo.Migrations.CreateInboxFunctions do
  use Ecto.Migration

  @functions [
    {"relay_private.inbox_commit(relay.inbox_items, boolean, timestamptz, text, text)",
     "relay_migrator", ~w(relay_owner)},
    {"relay_fn.inbox_deliver(uuid, uuid, text, text, text, text[], bytea, uuid, bytea, text, text, bigint, bigint)",
     "relay_owner", ~w(relay_app)},
    {"relay_fn.inbox_intent(uuid, uuid, text, bigint, timestamptz)", "relay_owner",
     ~w(relay_app)},
    {"relay_fn.inbox_retract(uuid, uuid[])", "relay_owner", ~w(relay_app)},
    {"relay_fn.inbox_timer_fire(uuid, uuid)", "relay_owner", ~w(relay_app)}
  ]

  # IN-1
  # IN-2
  # IN-4
  # IN-5
  # IN-9
  # IN-10
  # IN-11
  # IN-12
  # IN-16
  # IN-17
  # IN-18
  # IN-19
  # IN-22
  # IN-25
  # WF-29
  # E-13
  # OP-8
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down, do: :ok

  defp statements do
    [commit(), deliver(), intent(), retract(), timer_fire()]
  end

  defp commit do
    ~S"""
    CREATE FUNCTION relay_private.inbox_commit(p_item relay.inbox_items, p_new boolean,
      p_now timestamptz, p_event_type text, p_traceparent text)
      RETURNS bigint
    LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_item relay.inbox_items := p_item;
      v_stream text;
      v_epoch bigint;
      v_seq bigint;
      v_archived boolean;
      v_total boolean;
      v_unseen boolean;
      v_unread boolean;
      v_dt bigint;
      v_ds bigint;
      v_dr bigint;
      v_version bigint;
    BEGIN
      IF p_event_type NOT IN ('inbox.item_created', 'inbox.item_updated') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-26';
      END IF;
      SELECT m.stream_key INTO v_stream FROM relay.mailboxes m
        WHERE m.tenant_id = v_item.tenant_id AND m.environment = v_item.environment
          AND m.owner_kind = 'subscriber' AND m.owner_ref = v_item.recipient_id;
      IF v_stream IS NULL THEN
        SELECT e.stream_key INTO v_stream
          FROM relay_fn.mailbox_ensure(uuidv7(), 'subscriber', v_item.recipient_id) e;
      END IF;
      IF v_stream IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-1';
      END IF;
      v_archived := v_item.archived_at IS NOT NULL
        AND (v_item.unarchived_at IS NULL OR v_item.archived_at > v_item.unarchived_at);
      v_total := v_item.hidden_at IS NULL AND v_item.expired_at IS NULL
        AND (v_item.expires_at IS NULL OR v_item.expires_at > p_now)
        AND (v_item.snoozed_until IS NULL OR v_item.snoozed_until <= p_now)
        AND NOT v_archived;
      v_unseen := v_total
        AND NOT (v_item.seen_at IS NOT NULL AND v_item.seen_at >= v_item.last_activity_at);
      v_unread := v_total
        AND NOT (v_item.read_at IS NOT NULL AND v_item.read_at >= v_item.last_activity_at
          AND (v_item.unread_marked_at IS NULL OR v_item.read_at > v_item.unread_marked_at));
      v_dt := v_total::integer - COALESCE(v_item.counted_total, false)::integer;
      v_ds := v_unseen::integer - COALESCE(v_item.counted_unseen, false)::integer;
      v_dr := v_unread::integer - COALESCE(v_item.counted_unread, false)::integer;
      IF v_dt <> 0 OR v_ds <> 0 OR v_dr <> 0 THEN
        UPDATE relay.inbox_counters c
          SET unseen_count = c.unseen_count + v_ds, unread_count = c.unread_count + v_dr,
            total_count = c.total_count + v_dt, version = c.version + 1, updated_at = p_now
          WHERE c.tenant_id = v_item.tenant_id AND c.environment = v_item.environment
            AND c.recipient_id = v_item.recipient_id
          RETURNING c.version INTO v_version;
        IF NOT FOUND THEN
          INSERT INTO relay.inbox_counters (tenant_id, environment, recipient_id, unseen_count,
            unread_count, total_count, version, updated_at)
          VALUES (v_item.tenant_id, v_item.environment, v_item.recipient_id, v_ds, v_dr, v_dt, 1,
            p_now);
          v_version := 1;
        END IF;
      ELSE
        SELECT c.version INTO v_version FROM relay.inbox_counters c
          WHERE c.tenant_id = v_item.tenant_id AND c.environment = v_item.environment
            AND c.recipient_id = v_item.recipient_id;
        v_version := COALESCE(v_version, 0);
      END IF;
      SELECT o.epoch, o.seq INTO v_epoch, v_seq
        FROM relay_fn.outbox_append(uuidv7(), p_event_type, v_stream,
          jsonb_build_object('item_id', v_item.id, 'recipient_id', v_item.recipient_id,
            'state_version', v_item.state_version, 'counters_version', v_version),
          p_traceparent) o;
      v_item.counted_total := v_total;
      v_item.counted_unseen := v_unseen;
      v_item.counted_unread := v_unread;
      v_item.change_epoch := v_epoch;
      v_item.change_seq := v_seq;
      v_item.updated_at := p_now;
      IF p_new THEN
        v_item.created_epoch := v_epoch;
        v_item.created_seq := v_seq;
        INSERT INTO relay.inbox_items SELECT (v_item).*;
      ELSE
        UPDATE relay.inbox_items i SET delivery_id = v_item.delivery_id,
            message_class = v_item.message_class, retention_class = v_item.retention_class,
            category = v_item.category, tags = v_item.tags, severity = v_item.severity,
            content_ct = v_item.content_ct, content_key_id = v_item.content_key_id,
            content_digest = v_item.content_digest, locale = v_item.locale, dir = v_item.dir,
            activity_count = v_item.activity_count, actor_count = v_item.actor_count,
            last_activity_at = v_item.last_activity_at, expires_at = v_item.expires_at,
            expired_at = v_item.expired_at, snoozed_until = v_item.snoozed_until,
            seen_at = v_item.seen_at, read_at = v_item.read_at,
            unread_marked_at = v_item.unread_marked_at, archived_at = v_item.archived_at,
            unarchived_at = v_item.unarchived_at, hidden_at = v_item.hidden_at,
            hidden_reason = v_item.hidden_reason, counted_total = v_item.counted_total,
            counted_unseen = v_item.counted_unseen, counted_unread = v_item.counted_unread,
            state_version = v_item.state_version, change_epoch = v_item.change_epoch,
            change_seq = v_item.change_seq, updated_at = v_item.updated_at
          WHERE i.tenant_id = v_item.tenant_id AND i.environment = v_item.environment
            AND i.recipient_id = v_item.recipient_id AND i.id = v_item.id;
      END IF;
      RETURN v_version;
    END
    $fn$
    """
  end

  defp deliver do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_deliver(p_id uuid, p_delivery_id uuid, p_category text,
      p_group_key text, p_severity text, p_tags text[], p_content_ct bytea, p_content_key_id uuid,
      p_content_digest bytea, p_locale text, p_dir text, p_activity_count bigint,
      p_actor_count bigint)
      RETURNS TABLE (result text, item_id uuid, recipient_id uuid, state_version bigint,
        expires_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_delivery relay.deliveries;
      v_notification relay.notifications;
      v_on_expire text;
      v_item relay.inbox_items;
      v_existing uuid;
      v_outcome text;
      v_now timestamptz;
      v_expires timestamptz;
      v_class text;
    BEGIN
      PERFORM relay_private.assert_new_id(p_id);
      IF p_delivery_id IS NULL OR p_content_ct IS NULL OR p_content_key_id IS NULL
        OR p_content_digest IS NULL OR octet_length(p_content_digest) <> 32
        OR p_activity_count IS NULL OR p_activity_count < 1
        OR p_actor_count IS NULL OR p_actor_count < 0
        OR (p_tags IS NOT NULL AND cardinality(p_tags) > 10)
        OR (p_group_key IS NOT NULL AND octet_length(p_group_key) NOT BETWEEN 1 AND 128) THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-4';
      END IF;
      SELECT * INTO v_delivery FROM relay.deliveries d
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.id = p_delivery_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'delivery_not_found'::text, NULL::uuid, NULL::uuid, NULL::bigint,
          NULL::timestamptz;
        RETURN;
      END IF;
      IF v_delivery.channel::text <> 'in_app' THEN
        RETURN QUERY SELECT 'not_in_app'::text, NULL::uuid, NULL::uuid, NULL::bigint,
          NULL::timestamptz;
        RETURN;
      END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('inbox:' || v_tenant::text || v_env::text
        || v_delivery.recipient_id::text, 0));
      v_now := clock_timestamp();
      SELECT x.item_id INTO v_existing FROM relay.inbox_item_deliveries x
        WHERE x.tenant_id = v_tenant AND x.environment = v_env AND x.delivery_id = p_delivery_id;
      IF v_existing IS NOT NULL THEN
        SELECT * INTO v_item FROM relay.inbox_items i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env
            AND i.recipient_id = v_delivery.recipient_id AND i.id = v_existing;
        RETURN QUERY SELECT 'exists'::text, v_item.id, v_item.recipient_id, v_item.state_version,
          v_item.expires_at;
        RETURN;
      END IF;
      SELECT * INTO v_notification FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env
          AND n.id = v_delivery.notification_id;
      IF NOT EXISTS (SELECT 1 FROM relay.recipients r
        WHERE r.tenant_id = v_tenant AND r.environment = v_env
          AND r.id = v_notification.recipient_id AND r.kind = 'subscriber' AND r.state = 'active') THEN
        RETURN QUERY SELECT 'recipient_inactive'::text, NULL::uuid, NULL::uuid, NULL::bigint,
          NULL::timestamptz;
        RETURN;
      END IF;
      SELECT e.on_expire INTO v_on_expire FROM relay.events e
        WHERE e.tenant_id = v_tenant AND e.environment = v_env AND e.id = v_notification.event_id;
      v_expires := CASE WHEN v_on_expire = 'inbox_only' THEN NULL
        ELSE v_notification.expires_at END;
      v_class := CASE WHEN v_notification.message_class::text = 'marketing'
        THEN 'commercial_message' ELSE 'notification_content' END;
      SELECT * INTO v_item FROM relay.inbox_items i
        WHERE i.tenant_id = v_tenant AND i.environment = v_env
          AND i.recipient_id = v_notification.recipient_id
          AND i.notification_id = v_notification.id;
      IF FOUND THEN
        v_outcome := 'exists';
      ELSIF p_group_key IS NOT NULL THEN
        SELECT * INTO v_item FROM relay.inbox_items i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env
            AND i.recipient_id = v_notification.recipient_id AND i.group_key = p_group_key
            AND i.hidden_at IS NULL AND i.expired_at IS NULL
            AND (i.expires_at IS NULL OR i.expires_at > v_now)
          ORDER BY i.created_at DESC, i.id DESC
          LIMIT 1;
        IF FOUND THEN
          v_outcome := 'updated';
        END IF;
      END IF;
      IF v_outcome = 'updated' THEN
        v_item.delivery_id := p_delivery_id;
        v_item.message_class := v_notification.message_class::text;
        v_item.retention_class := v_class;
        v_item.category := p_category;
        v_item.tags := COALESCE(p_tags, ARRAY[]::text[]);
        v_item.severity := p_severity;
        v_item.content_ct := p_content_ct;
        v_item.content_key_id := p_content_key_id;
        v_item.content_digest := p_content_digest;
        v_item.locale := p_locale;
        v_item.dir := p_dir;
        v_item.activity_count := p_activity_count;
        v_item.actor_count := p_actor_count;
        v_item.last_activity_at := GREATEST(v_now, v_item.last_activity_at);
        v_item.expires_at := v_expires;
        v_item.state_version := v_item.state_version + 1;
        PERFORM relay_private.inbox_commit(v_item, false, v_now, 'inbox.item_updated',
          v_delivery.traceparent);
      ELSIF v_outcome IS NULL THEN
        v_outcome := 'created';
        v_item.tenant_id := v_tenant;
        v_item.environment := v_env;
        v_item.id := p_id;
        v_item.recipient_id := v_notification.recipient_id;
        v_item.subtenant_id := v_notification.subtenant_id;
        v_item.notification_id := v_notification.id;
        v_item.delivery_id := p_delivery_id;
        v_item.message_class := v_notification.message_class::text;
        v_item.retention_class := v_class;
        v_item.category := p_category;
        v_item.tags := COALESCE(p_tags, ARRAY[]::text[]);
        v_item.severity := p_severity;
        v_item.group_key := p_group_key;
        v_item.content_ct := p_content_ct;
        v_item.content_key_id := p_content_key_id;
        v_item.content_digest := p_content_digest;
        v_item.locale := p_locale;
        v_item.dir := p_dir;
        v_item.activity_count := p_activity_count;
        v_item.actor_count := p_actor_count;
        v_item.last_activity_at := v_now;
        v_item.expires_at := v_expires;
        v_item.counted_total := false;
        v_item.counted_unseen := false;
        v_item.counted_unread := false;
        v_item.state_version := 1;
        v_item.created_at := v_now;
        PERFORM relay_private.inbox_commit(v_item, true, v_now, 'inbox.item_created',
          v_delivery.traceparent);
      END IF;
      INSERT INTO relay.inbox_item_deliveries (tenant_id, environment, delivery_id, item_id,
        recipient_id, outcome, created_at)
      VALUES (v_tenant, v_env, p_delivery_id, v_item.id, v_item.recipient_id, v_outcome, v_now);
      PERFORM relay_fn.ledger_append(uuidv7(), p_delivery_id, NULL::bigint, 'relay',
        'attempt.succeeded', NULL::text, NULL::text, NULL::bigint, v_now, NULL::uuid,
        2::smallint, NULL::text, NULL::text, NULL::text, NULL::text,
        jsonb_build_object('inbox_item_id', v_item.id, 'inbox_outcome', v_outcome),
        v_delivery.traceparent);
      RETURN QUERY SELECT v_outcome, v_item.id, v_item.recipient_id, v_item.state_version,
        v_item.expires_at;
    END
    $fn$
    """
  end

  defp intent do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_intent(p_recipient_id uuid, p_item_id uuid, p_op text,
      p_base_state_version bigint, p_snooze_until timestamptz)
      RETURNS TABLE (result text, state_version bigint, counters_version bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_item relay.inbox_items;
      v_now timestamptz;
      v_changed boolean := false;
      v_seen boolean;
      v_read boolean;
      v_archived boolean;
      v_version bigint;
    BEGIN
      IF p_recipient_id IS NULL OR p_item_id IS NULL OR p_op IS NULL
        OR p_op NOT IN ('seen', 'read', 'unread', 'archive', 'unarchive', 'hide', 'snooze',
          'unsnooze') THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-12';
      END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('inbox:' || v_tenant::text || v_env::text
        || p_recipient_id::text, 0));
      v_now := clock_timestamp();
      SELECT * INTO v_item FROM relay.inbox_items i
        WHERE i.tenant_id = v_tenant AND i.environment = v_env
          AND i.recipient_id = p_recipient_id AND i.id = p_item_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::bigint, NULL::bigint;
        RETURN;
      END IF;
      SELECT c.version INTO v_version FROM relay.inbox_counters c
        WHERE c.tenant_id = v_tenant AND c.environment = v_env AND c.recipient_id = p_recipient_id;
      v_version := COALESCE(v_version, 0);
      IF p_op = 'snooze' AND (p_snooze_until IS NULL OR p_snooze_until <= v_now
        OR p_snooze_until > v_now + interval '366 days') THEN
        RETURN QUERY SELECT 'invalid'::text, v_item.state_version, v_version;
        RETURN;
      END IF;
      IF p_op IN ('unread', 'unarchive', 'unsnooze')
        AND p_base_state_version IS DISTINCT FROM v_item.state_version THEN
        RETURN QUERY SELECT 'conflict'::text, v_item.state_version, v_version;
        RETURN;
      END IF;
      IF v_item.hidden_at IS NOT NULL THEN
        RETURN QUERY SELECT 'unchanged'::text, v_item.state_version, v_version;
        RETURN;
      END IF;
      v_seen := v_item.seen_at IS NOT NULL AND v_item.seen_at >= v_item.last_activity_at;
      v_read := v_item.read_at IS NOT NULL AND v_item.read_at >= v_item.last_activity_at
        AND (v_item.unread_marked_at IS NULL OR v_item.read_at > v_item.unread_marked_at);
      v_archived := v_item.archived_at IS NOT NULL
        AND (v_item.unarchived_at IS NULL OR v_item.archived_at > v_item.unarchived_at);
      CASE p_op
        WHEN 'seen' THEN
          IF NOT v_seen THEN
            v_item.seen_at := GREATEST(v_now, v_item.last_activity_at);
            v_changed := true;
          END IF;
        WHEN 'read' THEN
          IF NOT v_read THEN
            v_item.read_at := GREATEST(v_now, v_item.last_activity_at,
              v_item.unread_marked_at + interval '1 microsecond');
            v_item.seen_at := GREATEST(v_item.seen_at, v_item.read_at);
            v_changed := true;
          END IF;
        WHEN 'unread' THEN
          IF v_read THEN
            v_item.unread_marked_at := GREATEST(v_now, v_item.read_at + interval '1 microsecond');
            v_changed := true;
          END IF;
        WHEN 'archive' THEN
          IF NOT v_archived THEN
            v_item.archived_at := GREATEST(v_now, v_item.unarchived_at + interval '1 microsecond');
            v_changed := true;
          END IF;
        WHEN 'unarchive' THEN
          IF v_archived THEN
            v_item.unarchived_at := GREATEST(v_now, v_item.archived_at + interval '1 microsecond');
            v_changed := true;
          END IF;
        WHEN 'hide' THEN
          v_item.hidden_at := v_now;
          v_item.hidden_reason := 'user';
          v_changed := true;
        WHEN 'snooze' THEN
          IF v_item.snoozed_until IS DISTINCT FROM p_snooze_until THEN
            v_item.snoozed_until := p_snooze_until;
            v_changed := true;
          END IF;
        WHEN 'unsnooze' THEN
          IF v_item.snoozed_until IS NOT NULL THEN
            v_item.snoozed_until := NULL;
            v_changed := true;
          END IF;
      END CASE;
      IF NOT v_changed THEN
        RETURN QUERY SELECT 'unchanged'::text, v_item.state_version, v_version;
        RETURN;
      END IF;
      v_item.state_version := v_item.state_version + 1;
      v_version := relay_private.inbox_commit(v_item, false, v_now, 'inbox.item_updated', NULL);
      RETURN QUERY SELECT 'applied'::text, v_item.state_version, v_version;
    END
    $fn$
    """
  end

  defp retract do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_retract(p_event_id uuid, p_notification_ids uuid[])
      RETURNS TABLE (result text, retracted bigint)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_ids uuid[];
      v_ref record;
      v_item relay.inbox_items;
      v_now timestamptz;
      v_count bigint := 0;
    BEGIN
      IF p_event_id IS NULL AND p_notification_ids IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-16';
      END IF;
      SELECT COALESCE(array_agg(n.id), ARRAY[]::uuid[]) INTO v_ids FROM relay.notifications n
        WHERE n.tenant_id = v_tenant AND n.environment = v_env
          AND (n.event_id = p_event_id OR n.id = ANY (COALESCE(p_notification_ids, ARRAY[]::uuid[])));
      FOR v_ref IN
        SELECT DISTINCT x.recipient_id, x.item_id
        FROM relay.deliveries d
        JOIN relay.inbox_item_deliveries x ON x.tenant_id = d.tenant_id
          AND x.environment = d.environment AND x.delivery_id = d.id
        WHERE d.tenant_id = v_tenant AND d.environment = v_env AND d.notification_id = ANY (v_ids)
        ORDER BY x.recipient_id, x.item_id
      LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended('inbox:' || v_tenant::text || v_env::text
          || v_ref.recipient_id::text, 0));
        v_now := clock_timestamp();
        SELECT * INTO v_item FROM relay.inbox_items i
          WHERE i.tenant_id = v_tenant AND i.environment = v_env
            AND i.recipient_id = v_ref.recipient_id AND i.id = v_ref.item_id;
        IF FOUND AND v_item.hidden_at IS NULL THEN
          v_item.hidden_at := v_now;
          v_item.hidden_reason := 'retracted';
          v_item.state_version := v_item.state_version + 1;
          PERFORM relay_private.inbox_commit(v_item, false, v_now, 'inbox.item_updated', NULL);
          v_count := v_count + 1;
        END IF;
      END LOOP;
      RETURN QUERY SELECT 'retracted'::text, v_count;
    END
    $fn$
    """
  end

  defp timer_fire do
    ~S"""
    CREATE FUNCTION relay_fn.inbox_timer_fire(p_recipient_id uuid, p_item_id uuid)
      RETURNS TABLE (result text, next_at timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
      v_item relay.inbox_items;
      v_now timestamptz;
      v_changed boolean := false;
      v_next timestamptz;
    BEGIN
      IF p_recipient_id IS NULL OR p_item_id IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-17';
      END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('inbox:' || v_tenant::text || v_env::text
        || p_recipient_id::text, 0));
      v_now := clock_timestamp();
      SELECT * INTO v_item FROM relay.inbox_items i
        WHERE i.tenant_id = v_tenant AND i.environment = v_env
          AND i.recipient_id = p_recipient_id AND i.id = p_item_id;
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'not_found'::text, NULL::timestamptz;
        RETURN;
      END IF;
      IF v_item.snoozed_until IS NOT NULL AND v_item.snoozed_until <= v_now THEN
        v_item.snoozed_until := NULL;
        v_changed := true;
      END IF;
      IF v_item.expires_at IS NOT NULL AND v_item.expired_at IS NULL
        AND v_item.expires_at <= v_now THEN
        v_item.expired_at := v_now;
        v_changed := true;
      END IF;
      IF v_changed THEN
        v_item.state_version := v_item.state_version + 1;
        PERFORM relay_private.inbox_commit(v_item, false, v_now, 'inbox.item_updated', NULL);
      END IF;
      IF v_item.hidden_at IS NULL THEN
        v_next := LEAST(v_item.snoozed_until,
          CASE WHEN v_item.expired_at IS NULL THEN v_item.expires_at END);
      END IF;
      RETURN QUERY SELECT CASE WHEN v_changed THEN 'fired' ELSE 'not_due' END, v_next;
    END
    $fn$
    """
  end
end
